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

    def initialize(store:, picker:, pool:, my_pubkey: nil,
                   now: -> { Time.now.to_i }, logger: $stderr)
      @store = store
      @picker = picker
      @pool = pool
      @my_pubkey = my_pubkey
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
      # EM callbacks (per relay), dial threads and the tick thread all touch
      # this state — one non-reentrant lock, bodies in *_unlocked internals.
      @mutex = Mutex.new
      seed_my_relays
    end

    attr_reader :followed

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
          "read" => e["read"], "inbox" => e["inbox"], "write" => e["write"],
          "outbox" => e["outbox"], "discover" => e["discover"], "search" => e["search"] == true }
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

    # Everyone whose notes we stream: explicit follows + ourself (own posts
    # must load and stay live without having to follow yourself).
    def persons
      (@followed + [@my_pubkey].compact).uniq
    end

    # TUI needs to know which reactions are its own (info frame "me").
    def pubkey = @my_pubkey

    def tick
      @mutex.synchronize { tick_unlocked }
      dial_pending
    end

    # Flush queued dials OUTSIDE the lock (see @pending_dials note). Re-tick
    # afterwards so subscriptions attach to freshly connected relays.
    def dial_pending
      urls = nil
      @mutex.synchronize do
        urls = @pending_dials.uniq
        @pending_dials = []
      end
      return if urls.empty?

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

    # --- inbound (called by RelayPool) ---

    # Returns contact pubkeys newly adopted from OUR kind 3 (empty normally);
    # the caller merges them via follow() OUTSIDE the mutex (follow re-locks).
    def ingest(url, ev)
      adopted = nil
      @mutex.synchronize { adopted = ingest_unlocked(url, ev) }
      follow(*adopted) if adopted.is_a?(Array) && adopted.any?
      adopted
    end

    def relay_failed(url)
      @mutex.synchronize { relay_failed_unlocked(url) }
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

    def relay_failed_unlocked(url)
      @picker.relay_disconnected(url, 300)
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

    # Keep live REQ subscriptions aligned with the picker's assignments.
    # One batched home stream per connected relay: every person in a single
    # REQ (kinds 1 + 1111). The old per-person fan-out starved the pool's
    # per-connection REQ cap of 8 — past ~8 follows, every new stream queued
    # forever and the home feed froze at startup history. NIP-01 re-REQ with
    # the same sub_id swaps the relay's filter in place, so the follow set
    # can change without touching slots or queues.
    def sync_subscriptions
      persons = self.persons.sort
      sig = persons.join(",")
      @pool.connections.keys.sort.each do |url|
        if @home_subs[url].nil?
          next unless @pool.subscribe_home(url, "home", persons)

          @home_subs[url] = "home"
          @home_sigs[url] = sig
          @logger.puts "home: streaming #{persons.size} authors via #{url.delete_prefix('wss://')}"
        elsif @home_sigs[url] != sig && @pool.refresh_home(url, "home", persons)
          @home_sigs[url] = sig
        end
      end
      (@home_subs.keys - @pool.connections.keys).each do |url|
        @home_subs.delete(url)
        @home_sigs.delete(url)
      end
      # Still dial relays the picker picked for seek affinity.
      @picker.assignments.each_key do |url|
        @pending_dials << url unless @pool.connections.key?(url)
      end
      # Gossip switch wiring: an advertised inbox (or discover) relay is a
      # dial target of its own — evidence-based picking alone never reaches
      # a relay we have never fetched from (e.g. paid relays).
      @store.my_relays.each do |r|
        next unless r["inbox"] || r["discover"]
        next if @pool.connections.key?(r["url"])

        @pending_dials << r["url"]
      end
    end

    # Seeker: refresh relay lists that are stale (>7 days) or unknown,
    # with exponential backoff per person (1min doubling, capped at 1h).
    def seek_stale(max_age: 7 * 24 * 3600)
      urls = @pool.connections.keys.sort
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

    # Profiles (kind 0) label the TUI. Batched politeness: ONE REQ with up to
    # PROFILE_BATCH authors per try, rotating relays — how clients are
    # expected to sync metadata. A productive batch re-fires next tick; an
    # empty one backs off exponentially.
    def seek_profiles
      urls = @pool.connections.keys.sort
      return if urls.empty?
      return if @now.call < @prof_batch_at

      stale = (persons + [@my_pubkey]).compact.uniq.reject { |pk| fresh_profile?(pk) }
      return if stale.empty?

      pks = stale.first(PROFILE_BATCH)
      candidates = ((pks.flat_map { |pk| @store.person_relay_urls(pk) } & urls).uniq + urls).uniq
      url = candidates[@prof_batch_tries % candidates.size]
      return unless @pool.seek_profiles(url, "prof#{@prof_batch_tries}", pks)

      @logger.puts "prof-batch: #{pks.size} authors via #{url.delete_prefix('wss://')}"
      @prof_batch_tries += 1
      if @prof_batch_hits > @prof_batch_hits_at_batch
        @prof_batch_miss = 0
        @prof_batch_at = @now.call + 1 # next tick keeps walking
      else
        @prof_batch_miss += 1
        @prof_batch_at = @now.call + [60 * 2**@prof_batch_miss, 3600].min
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
      (known + connected).uniq
    end

    # Our own kind-3 contact list adopts the account's real follows: refresh
    # hourly (one relay per try, rotating — cheap one-shot), so follows made
    # elsewhere land here too.
    def seek_own_contacts
      return unless @my_pubkey

      now = @now.call
      return if @contacts_at[@my_pubkey] > now - 3600

      urls = @pool.connections.keys.sort
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

      @store.record_fetch(url, pubkey, @now.call)
    end
  end
end
