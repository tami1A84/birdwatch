# frozen_string_literal: true

require "json"
require_relative "../nostr_core/event"
require_relative "../nostr_core/relay_picker"
require_relative "relay_pool"
require_relative "store"

module Nostrd
  # Wires Store + RelayPicker + RelayPool into the live machine.
  # tick(): evidence → scores → picks → subscription diff.
  # ingest(): relay traffic → events in store, evidence updates, 10002 discovery.
  class Orchestrator
    # Per-tick caps for one-shot seeks: the first ticks after login must walk
    # the follow list, not burst N REQs at one relay.
    RELAY_SEEKS_PER_TICK = 8
    # Profile sync is one batched authors-REQ per try (rotating relays).
    PROFILE_BATCH = 100
    # One profile batch is fanned over several relays per try: a single relay
    # rarely knows all 100 authors, and one-relay-per-30s-tick rotation made
    # names crawl in at boot.
    PROFILE_FANOUT = 3
    # Mentions + NIP-17 inbox filter: kind 1059 (gift wrap) rides the same
    # p-tagged sub so private DMs arrive without a second REQ slot.
    INBOX_KINDS = [1, 7, 1111, 1059].freeze

    def initialize(store:, picker:, pool:, my_pubkey: nil, bunker: nil, dm: nil,
                   now: -> { Time.now.to_i }, logger: $stderr)
      @store = store
      @picker = picker
      @pool = pool
      @my_pubkey = my_pubkey
      @bunker = bunker # Nostrd::Bunker, optional (nil = transport disabled)
      @dm = dm # Nostrd::Dm, optional (nil = NIP-17 gift wraps are ignored)
      @now = now
      @logger = logger
      @followed = []
      @home_subs = {} # url => sub_id — one batched home stream per relay
      @home_sigs = {} # url => persons-sig when the filter was last sent
      @seek_at = Hash.new(0)
      @seek_tries = Hash.new(0)
      @contacts_at = Hash.new(0) # own kind-3 refresh gate (hourly)
      @contact_tries = Hash.new(0) # relay rotation across contact seeks
      @prof_batch_at = 0 # batched profile-sync gate (seek_profiles)
      @prof_batch_tries = 0
      @prof_batch_miss = 0
      @prof_batch_hits = 0
      @prof_batch_hits_at_batch = 0
      @last_assign_sig = nil
      # Dial targets queued by sync_subscriptions, flushed OUTSIDE @mutex by
      # dial_pending: connect() may block seconds (handshake gate) and fires
      # on_disconnect -> relay_failed synchronously on failure, which would
      # re-enter the non-reentrant @mutex if dialed under the lock.
      @pending_dials = []
      # Same story for hang-ups: relays that lost their purpose (assignment
      # gone, not ours, no bunker duty) are disconnected outside the lock.
      @pending_disconnects = []
      # URL of the embedded loopback relay (bin/nostrd wires it after start).
      # Loopback is our own store mirrored over NIP-01: fetches through it are
      # not network evidence, its dial failures never penalty-box, and its
      # home stream replays nothing (since boot) because it IS our history.
      @local_relay_url = nil
      @booted_at = @now.call
      # EM callbacks (per relay), dial threads and the tick thread all touch
      # this state — one non-reentrant lock, bodies in *_unlocked internals.
      @mutex = Mutex.new
      seed_my_relays
    end

    attr_reader :followed
    attr_accessor :local_relay_url
    attr_reader :booted_at

    # First boot: seed gossip switches from the published NIP-65 list
    # (marker nil = both advertised halves). Local-only state.
    def seed_my_relays
      return unless @my_pubkey && @store.my_relays.empty?

      @store.relay_list_for(@my_pubkey).each do |r|
        @store.upsert_my_relay(r["url"], read: true,
                               inbox: r["read"], write: true, outbox: r["write"],
                               discover: false)
      end
    end

    # Per-switch toggle from the TUI. Dependencies: inbox implies read,
    # outbox implies write (gossip semantics). Local-only; no publication.
    def set_relay_flags(url, flags)
      cur = @store.my_relay(url) ||
            { "url" => url, "read" => true, "inbox" => false,
              "write" => true, "outbox" => false, "discover" => false }
      merged = cur.merge(flags.transform_keys(&:to_s))
      merged["read"] = true if merged["inbox"]
      merged["write"] = true if merged["outbox"]
      @store.upsert_my_relay(url, read: merged["read"], inbox: merged["inbox"],
                             write: merged["write"], outbox: merged["outbox"],
                             discover: merged["discover"], search: merged["search"] == true)
      @store.my_relay(url)
    end

    # TUI relay management: add (defaults: hidden read+write) / remove.
    def add_my_relay(url)
      url = url.to_s
      raise ArgumentError, "relay url must start with ws" unless url.start_with?("ws")

      @store.upsert_my_relay(url, read: true, inbox: false, write: true,
                             outbox: false, discover: false, search: false)
      @store.my_relay(url)
    end

    def remove_my_relay(url) = @store.remove_my_relay(url)

    # Blossom server list (NIP-B7 kind 10063). Source of truth: the local
    # override file (~/.config/nostrd/blossom.json, edited from the TUI),
    # falling back to our published kind-10063 event, then baked defaults.
    def blossom_servers
      file = File.expand_path("~/.config/nostrd/blossom.json")
      if File.readable?(file)
        urls = Array(JSON.parse(File.read(file))).filter_map do |u|
          u if u.to_s.match?(%r{\Ahttps?://\S+\z})
        end
        return urls unless urls.empty?
      end
      mine = (pk = self.pubkey) ? @store.blossom_servers_for(pk) : []
      return mine unless mine.empty?

      Nostrd::Blossom::DEFAULT_SERVERS.dup
    end

    # The kind-10002 payload: inbox => advertised read, outbox => advertised
    # write, both => nil marker. Hidden read/write relays stay out.
    def advertised_relay_list
      @store.my_relays.filter_map do |r|
        next unless r["inbox"] || r["outbox"]

        marker = r["inbox"] && r["outbox"] ? nil : (r["outbox"] ? "w" : "r")
        { "url" => r["url"], "marker" => marker }
      end
    end

    # For the SSS info panel: who we follow and what is dialed right now.
    # Gossip-style relay panel: switches from my_relays (local config) with
    # live connection state; relays dialed but unconfigured show as hidden
    # read+write. Inbox/Outbox are the advertised halves.
    def relay_status
      mine = @store.my_relays
      by_url = mine.each_with_object({}) { |r, h| h[r["url"]] = r }
      (@pool.connections.keys | by_url.keys).sort.map do |url|
        e = by_url[url] ||
            { "url" => url, "read" => true, "inbox" => false,
              "write" => true, "outbox" => false, "discover" => false }
        { "url" => url,
          "state" => @pool.connections.key?(url) ? "connected" : "offline",
          "mine" => by_url.key?(url),
          "read" => e["read"], "inbox" => e["inbox"], "write" => e["write"],
          "outbox" => e["outbox"], "discover" => e["discover"], "search" => e["search"] == true,
          "covers" => @picker.assignments[url]&.size }
      end
    end

    def follow(*pubkeys)
      @mutex.synchronize do
        @followed = (@followed + pubkeys).uniq
        pubkeys.each { |pk| @store.save_follow(pk) if @store.respond_to?(:save_follow) }
        tick_unlocked
      end
      dial_pending
    end

    # Remove a follow: state + store, then re-sync subscriptions. Nothing to
    # dial — the person's relays simply stop being interesting.
    def unfollow(*pubkeys)
      @mutex.synchronize do
        @followed -= pubkeys
        pubkeys.each { |pk| @store.remove_follow(pk) if @store.respond_to?(:remove_follow) }
        tick_unlocked
      end
    end

    # Everyone whose notes we stream: explicit follows + ourself (own posts
    # must load and stay live without having to follow yourself).
    def persons
      (@followed + [@my_pubkey].compact).uniq
    end

    # Relays worth ASKING for things we might be missing. The loopback
    # mirrors our own store — anything it can serve, the info frame and
    # broadcast_profile already delivered — so seeking from it only burns
    # rotation tries (and starts their backoff clocks) or "answers" with
    # stale cached data, postponing the real network refresh.
    def network_urls
      @pool.connections.keys.sort - [@local_relay_url]
    end

    # TUI needs to know which reactions are its own (info frame "me").
    def pubkey = @my_pubkey

    def tick
      @mutex.synchronize { tick_unlocked }
      dial_pending
    end

    # Flush queued dials and hang-ups OUTSIDE the lock (see @pending_dials
    # note). Re-tick afterwards so subscriptions attach to fresh relays.
    def dial_pending
      urls, drops = nil, nil
      @mutex.synchronize do
        urls = @pending_dials.uniq
        @pending_dials = []
        drops = @pending_disconnects.uniq - urls
        @pending_disconnects = []
      end
      return if urls.empty? && drops.empty?

      # Hang up first: a dropped connection frees the relay's view of us and
      # cannot race the dial of the same url (drops never share urls with dials).
      drops.each do |url|
        begin
          @pool.disconnect(url)
        rescue StandardError => e
          @logger.puts "orchestrator: disconnect #{url} failed: #{e.class}: #{e.message}"
        end
      end
      urls.each do |url|
        begin
          @pool.connect(url)
        rescue StandardError => e
          @logger.puts "orchestrator: dial #{url} failed: #{e.class}: #{e.message}"
        end
      end
      @mutex.synchronize { tick_unlocked }
    end

    # NIP-65 outbox: our own write relays (from our kind-10002), best first.
    def write_relays
      return [] unless @my_pubkey

      @store.write_relays_for(@my_pubkey)
    end

    # NIP-17: where a person listens — the inbox (read) half of their newest
    # author-signed kind 10002. Gift wraps are published ONLY to these
    # relays; the claim, not a decayed evidence score, decides delivery.
    def inbox_relays_for(pubkey)
      @store.relay_claims_for(pubkey, usage: :read)
    end

    # Sign+publish path for the Dm service: publish to exactly the given
    # relays (no gossip fan-out — DMs are addressed traffic). If none of
    # them are dialed, fall back to the connected set: a gift wrap is
    # ciphertext to everyone but the recipient, so a wide publish leaks
    # nothing but availability.
    def publish_to(urls, event)
      urls = Array(urls) & @pool.connections.keys
      urls = @pool.connections.keys if urls.empty?
      @pool.publish(event, urls: urls)
    end

    # --- inbound (called by RelayPool) ---

    # Returns contact pubkeys newly adopted from OUR kind 3 (empty normally);
    # the caller merges them via follow() OUTSIDE the mutex (follow re-locks).
    def ingest(url, ev)
      adopted = nil
      @mutex.synchronize { adopted = ingest_unlocked(url, ev) }
      follow(*adopted) if adopted.is_a?(Array) && adopted.any?
      adopted
    end

    def relay_failed(url, penalty = 300)
      @mutex.synchronize { relay_failed_unlocked(url, penalty) }
      dial_pending
    end

    # --- internals (call only while holding @mutex) ---

    def tick_unlocked
      refresh_scores
      @picker.garbage_collect(persons) # persons, not @followed: own stream survives
      @picker.pick_all
      sync_subscriptions
      seek_stale
      seek_profiles
      seek_own_contacts
      self
    end

    def ingest_unlocked(url, ev)
      @store.record_relay_result(url, success: true)
      return false unless ev.is_a?(Hash) && ev["id"]

      # NIP-17: kind 1059 is sealed ciphertext addressed to us — the Dm
      # service unwraps and upserts the inner kind-14 rumor; the ciphertext
      # itself never enters the store.
      if ev["kind"] == 1059
        @dm&.handle_gift_wrap(ev, url)
        return true
      end

      @store.upsert_event(NostrCore::Event.from_h(ev))
      case ev["kind"]
      when 10002
        learn_relay_list(ev)
      when 3
        # Our own contact list: adopt its p-tagged pubkeys as follows (the
        # merge itself happens outside the mutex — see ingest).
        return contact_pubkeys(ev) if ev["pubkey"] == @my_pubkey
      when 0
        @store.upsert_profile(NostrCore::Event.from_h(ev))
        note_profile_arrival(ev["pubkey"])
      end
      learn_fetch(url, ev["pubkey"])
      true
    end

    def relay_failed_unlocked(url, penalty)
      # Loopback is not a network peer: a failed self-dial retries on the
      # next tick instead of poisoning the picker's assignments for 5 minutes
      # (the loopback carries the most evidence, so a 300s box starved the
      # whole home feed of its fastest source).
      penalty = 0 if url == @local_relay_url
      @picker.relay_disconnected(url, penalty)
      @home_subs.delete(url)
      @home_sigs.delete(url)
      tick_unlocked
    end

    # --- internals ---

    def refresh_scores
      persons.each do |pk|
        scores = @store.best_relays_for(pk)
        @picker.add_someone(pk, scores) unless scores.empty?
      end
    end

    # Keep live REQ subscriptions aligned with the gossip model
    # (mikedilger.com/gossip-model): each person's events are fetched from
    # their best ~3 relays — exactly the RelayPicker's assignments — instead
    # of every connected relay streaming everyone. Two relays still stream
    # the full person set: the loopback relay (our own store of record) and
    # user-configured inbox/discover relays (bootstrap: a fresh follow has
    # no evidence until its kind-10002 lands; those relays carry it while
    # the picker has nothing to place it on). One batched home REQ per
    # relay; a changed author set re-sends the same sub_id and swaps the
    # filter in place (NIP-01). A relay that loses its assignment entirely
    # gets its home stream CLOSED and — unless it is loopback / configured /
    # a bunker target — is hung up: connections exist to fetch specific
    # people, not for their own sake.
    def sync_subscriptions
      persons = self.persons.sort
      assignments = @picker.assignments
      bootstrap = bootstrap_relay_urls
      @pool.connections.keys.sort.each do |url|
        authors = home_authors_for(url, persons, assignments, bootstrap)
        since = url == @local_relay_url ? @booted_at : nil
        if authors.nil?
          drop_home(url, bootstrap)
        elsif @home_subs[url].nil?
          next unless @pool.subscribe_home(url, "home", authors, since: since)

          @home_subs[url] = "home"
          @home_sigs[url] = authors
          @logger.puts "home: streaming #{authors.size} authors via #{url.delete_prefix('wss://')}"
        elsif @home_sigs[url] != authors && @pool.refresh_home(url, "home", authors, since: since)
          @home_sigs[url] = authors
        end
      end
      (@home_subs.keys - @pool.connections.keys).each do |url|
        @home_subs.delete(url)
        @home_sigs.delete(url)
      end
      dial_targets(assignments)
      # NIP-46 bunker: re-check each tick so the persistent kind-24133 sub
      # survives relay reconnects, and dial the relays advertised in the
      # bunker:// URI even when gossip never picks them. Subscribing an
      # unconnected target is fine — queue_req holds the frame until the
      # dial completes.
      if @bunker
        # network_urls, not all connections: the loopback only ever holds OUR
        # copies of past traffic (clients cannot publish to it), so its
        # bunker sub is pure replay — at boot it re-delivered days of
        # kind-24133 history and the signer spent minutes re-answering dead
        # requests, pegging both loopback threads at 100% CPU.
        @bunker.ensure_subscribed((network_urls + @bunker.relay_targets).uniq)
        @bunker.relay_targets.each do |url|
          @pending_dials << url unless @pool.connections.key?(url)
        end
      end
      # Mentions + NIP-17 inbox: one persistent per-relay sub p-tagged to us,
      # re-issued every tick like the bunker sub (relay drops clear live
      # subs, and a queued-but-never-started sub is invisible on the wire).
      # Loopback excluded, same replay logic as the bunker sub.
      if @my_pubkey
        @pool.connections.keys.sort.each do |url|
          next if url == @local_relay_url
          next if @pool.sub_live?(url, "inbox")

          @pool.subscribe_inbox(url, "inbox", @my_pubkey, kinds: INBOX_KINDS)
        end
      end
    end

    # The home author set for one relay under the gossip model (see
    # sync_subscriptions): its assigned people, PLUS everyone the picker
    # could not place yet — fresh follows ride every open connection until
    # their kind-10002 lands and evidence narrows the net onto their best
    # ~3 relays. Loopback and user-configured inbox/discover relays always
    # stream the full set. nil = no home stream on this relay.
    def home_authors_for(url, persons, assignments, bootstrap)
      return persons if url == @local_relay_url || bootstrap.include?(url)

      covered = assignments[url] || []
      uncovered = persons - assignments.values.flatten
      return nil if covered.empty? && uncovered.empty?

      (covered | uncovered).sort
    end

    # Relays the user explicitly put to work (config, not evidence): they
    # bootstrap coverage for people the picker cannot place yet.
    def bootstrap_relay_urls
      @store.my_relays.select { |r| r["inbox"] || r["discover"] }.map { |r| r["url"] }
    end

    # Close the home stream of a relay with no assignment; hang up entirely
    # when nothing else needs the connection. Queued outside the lock —
    # disconnect fires on_disconnect -> relay_failed (see @pending_dials).
    def drop_home(url, bootstrap)
      if @home_subs.delete(url)
        @home_sigs.delete(url)
        @pool.transmit_close(url, "home")
        @logger.puts "home: closing stream via #{url.delete_prefix('wss://')} (unassigned)"
      end
      return if url == @local_relay_url || bootstrap.include?(url) ||
                (@bunker && @bunker.relay_targets.include?(url))

      # key? guard: once dropped, later ticks must not re-queue the hang-up
      # (disconnect would re-fire on_disconnect every tick).
      @pending_disconnects << url if @pool.connections.key?(url)
    end

    # Dial queue, most important first: configured relays (loopback among
    # them — connect before any network dial so the relay tab never shows it
    # waiting behind a 5s-dead gossip pick), then the picker's assignment
    # dials, then bunker targets (queued in the bunker block above).
    def dial_targets(assignments)
      @store.my_relays.each do |r|
        next unless r["inbox"] || r["discover"]
        next if @pool.connections.key?(r["url"])

        @pending_dials << r["url"]
      end
      assignments.each_key do |url|
        @pending_dials << url unless @pool.connections.key?(url)
      end
    end

    # Seeker: refresh relay lists that are stale (>7 days) or unknown,
    # with exponential backoff per person (1min doubling, capped at 1h).
    def seek_stale(max_age: 7 * 24 * 3600)
      urls = network_urls
      return [] if urls.empty?

      budget = RELAY_SEEKS_PER_TICK
      persons.filter_map do |pk|
        break [] if budget <= 0
        next nil if fresh_relay_list?(pk, max_age) || @now.call < @seek_at[pk]

        # One relay per try, rotating across retries — a well-behaved client
        # does not fan every seek out to every relay; if this relay lacks the
        # list, the backoff retry lands on the next one. Relays where we have
        # already seen this person are tried first (they know the author).
        candidates = candidate_relays(pk, urls)
        url = candidates[@seek_tries[pk] % candidates.size]
        next nil unless @pool.seek_relay_list(url, "seek#{pk[0, 6]}", pk)

        @logger.puts "seek: #{pk[0, 8]} via #{url.delete_prefix('wss://')}"
        @seek_tries[pk] += 1
        @seek_at[pk] = @now.call + [60 * 2**@seek_tries[pk], 3600].min
        budget -= 1
        [url, pk]
      end
    end

    def fresh_relay_list?(pk, max_age)
      newest = @store.newest_relay_list_at(pk)
      newest && (@now.call - newest) < max_age
    end

    # Profiles (kind 0) label the TUI. Batched politeness: ONE REQ with up
    # to PROFILE_BATCH authors per try, fanned over PROFILE_FANOUT relays at
    # once (a single relay rarely knows all 100), sliding one relay per try —
    # how clients are expected to sync metadata. A productive batch re-fires
    # next tick; an empty one backs off exponentially.
    def seek_profiles
      urls = network_urls
      return if urls.empty?
      return if @now.call < @prof_batch_at

      stale = (persons + [@my_pubkey]).compact.uniq.reject { |pk| fresh_profile?(pk) }
      return if stale.empty?

      pks = stale.first(PROFILE_BATCH)
      # Evidence-backed relays first (they know these people), then the rest.
      candidates = ((pks.flat_map { |pk| @store.person_relay_urls(pk) } & urls).uniq + urls).uniq
      fan_urls = (0...PROFILE_FANOUT).map { |i| candidates[(@prof_batch_tries + i) % candidates.size] }.uniq
      fan = fan_urls.each_with_index.filter_map do |url, i|
        @pool.seek_profiles(url, "prof#{@prof_batch_tries}x#{i}", pks) ? url : nil
      end
      return if fan.empty?

      @logger.puts "prof-batch: #{pks.size} authors via #{fan.map { |u| u.delete_prefix('wss://') }.join(' + ')}"
      @prof_batch_tries += 1
      if @prof_batch_hits > @prof_batch_hits_at_batch
        @prof_batch_miss = 0
        @prof_batch_at = @now.call + 1 # next tick keeps walking
      else
        @prof_batch_miss += 1
        @prof_batch_at = @now.call + [30 * 2**@prof_batch_miss, 600].min
      end
      @prof_batch_hits_at_batch = @prof_batch_hits
    end

    # A profile is fresh only when it can actually label the author. A row
    # with all fields nil (empty kind 0 content) keeps being seeked: the
    # rotation's next retry lands on a different relay.
    def fresh_profile?(_pk)
      profile = @store.profile_for(_pk)
      profile && profile.values_at("name", "display_name", "nip05", "picture", "about").any?
    end

    # kind 0 arrival: a usable one feeds the batch-yield signal so the next
    # batch re-fires immediately; an empty one changes nothing (the person
    # stays stale for the next batch on another relay).
    def note_profile_arrival(pk)
      @prof_batch_hits += 1 if fresh_profile?(pk)
    end

    # Where to ask about this person: relays already associated with them
    # (write-first, see Store#person_relay_urls) that are connected, then the
    # remaining connected relays as rotation fallback.
    def candidate_relays(pk, connected)
      known = @store.person_relay_urls(pk) & connected
      (known + connected).uniq - [@local_relay_url]
    end

    # Our own kind-3 contact list adopts the account's real follows: refresh
    # hourly (one relay per try, rotating — cheap one-shot), so follows made
    # elsewhere land here too.
    def seek_own_contacts
      return unless @my_pubkey

      now = @now.call
      return if @contacts_at[@my_pubkey] > now - 3600

      urls = network_urls
      return if urls.empty?

      url = urls[@contact_tries[@my_pubkey] % urls.size]
      return unless @pool.seek_contact_list(url, "contacts#{@my_pubkey[0, 6]}", @my_pubkey)

      @logger.puts "contacts: seeking own kind 3 via #{url.delete_prefix('wss://')}"
      @contact_tries[@my_pubkey] += 1
      @contacts_at[@my_pubkey] = now
    end

    def contact_pubkeys(ev)
      ev["tags"].filter_map do |tag|
        next unless tag.is_a?(Array) && tag[0] == "p"

        pk = tag[1]
        pk if pk.is_a?(String) && pk.size == 64
      end.uniq - @followed
    end

    def learn_relay_list(ev)
      @store.upsert_person_relay_list(ev["pubkey"], ev["tags"], @now.call)
      @seek_tries.delete(ev["pubkey"])
      @seek_at.delete(ev["pubkey"])
      ev["tags"].each do |tag|
        next unless tag.is_a?(Array) && tag[0] == "r" && tag[1].to_s.start_with?("ws")

        @store.upsert_relay(NostrCore::Relay.new(url: tag[1]))
      end
      # Our own list: keep our NIP-65 write relays dialed so publishes reach
      # the right outboxes (previously only in the hourly self-seek path).
      @pending_dials.concat(write_relays - @pool.connections.keys) if ev["pubkey"] == @my_pubkey
    end

    def learn_fetch(url, pubkey)
      return unless pubkey
      # The loopback relay serves our own store: recording fetches from it
      # would make it the top-scoring relay for every person and crowd real
      # network relays out of the top-3 (its rows are purged at boot too).
      return if url == @local_relay_url

      @store.record_fetch(url, pubkey, @now.call)
    end
  end
end
