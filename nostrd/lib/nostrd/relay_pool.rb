# frozen_string_literal: true

require "json"
require_relative "../nostr_core/relay"
require_relative "../nostr_core/subscription"

module Nostrd
  # Live WebSocket connections to relays. Wire transport is injected so the
  # logic stays testable without network (stub transport in tests).
  class RelayPool
    def initialize(transport_class: nil, on_event:, on_disconnect:,
                   on_publish_result: nil, on_eose: nil, penalty_seconds: 300,
                   max_subs_per_conn: 8, logger: $stderr)
      @transport_class = transport_class # lazy: Nostrd::WsTransport in production
      @on_event = on_event
      @on_disconnect = on_disconnect
      @on_publish_result = on_publish_result
      @on_eose = on_eose # -> (url, sub_id); one-shot subs are CLOSED after it
      @auth = nil # set via auth_with: NIP-42 challenge -> signed kind 22242
      @penalty_seconds = penalty_seconds
      @max_subs = max_subs_per_conn # politeness: relays throttle concurrent REQs
      @logger = logger
      @connections = {} # url => transport
      @connecting = []  # urls mid-handshake: two threads must never dial one url
      @mos = Mutex.new  # guards @connections + @connecting (dial/closer threads race)
      @one_shot = {} # url => [sub_ids] — seeks are done after their EOSE
      @live_subs = {} # url => [sub_ids] — REQs actually sent (occupy a slot)
      @queued = {} # url => [[sub_id, frame, one_shot?]] — waiting for a slot
    end

    attr_reader :connections

    # NIP-42 wiring: block returns the signed auth event for a challenge.
    def auth_with(&block)
      @auth = block
    end

    # One url, one connection — always. The dial (blocking handshake, up to
    # HANDSHAKE_TIMEOUT) happens OUTSIDE @mos so a dead relay cannot stall
    # closes, but the check-and-claim of the url is atomic: tick threads,
    # relay_failed threads and the boot dials all race here, and the old
    # last-write-wins behaviour leaked a live duplicate socket per collision
    # (logs showed the same relay "connected" twice in a single boot).
    def connect(url)
      url = NostrCore.normalize_relay_url(url)
      @mos.synchronize do
        return nil if @connections.key?(url) || @connecting.include?(url)

        @connecting << url
      end

      klass = @transport_class
      unless klass
        require_relative "ws_client" # lazy: pulls socket/openssl stack
        klass = Nostrd::WsTransport  # v2: single mux reader thread for all conns
      end
      transport = klass.new(url)
      transport.open # blocking handshake; raises if the relay is dead
      won = false
      @mos.synchronize do
        @connecting.delete(url)
        unless @connections.key?(url)
          # Callbacks registered only once we own the slot: a loser
          # transport's close must not fire on_close and drop the winner's
          # connection. (Unreachable while the claim above holds — insurance.)
          transport.on_message { |data| handle_frame(url, data) }
          transport.on_close { drop(url, penalty: true) }
          @connections[url] = transport
          won = true
        end
      end
      if won
        @logger.puts "pool: connected #{url}"
      else
        transport.close
      end
      url
    rescue StandardError => e
      @mos.synchronize { @connecting.delete(url) }
      @logger.puts "pool: #{url} failed: #{e.class}"
      drop(url, penalty: true)
      nil
    end

    # Stream a person's notes from one assigned relay (RelayPicker's assignment).
    # NOTE: no limit key — strfry treats limit:0 as "zero events".
    # One batched home stream per relay. The old per-person fan-out (1 REQ
    # each) starved the pool's per-connection cap of 8 — once follows
    # outgrew 8, every new stream queued forever and the home feed froze at
    # whatever history was cached at startup. `since` bounds the initial
    # replay: the loopback relay serves our OWN store, so replaying history
    # there only re-ingests what we already have (hundreds of events of
    # mutex/SQLite churn at every boot) — live push needs no history.
    def subscribe_home(url, sub_id, pubkeys, since: nil)
      filter = { authors: pubkeys, kinds: [1, 7, 1111] }
      filter[:since] = since if since
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, filter), false)
    end

    # Single-author stream (kept for tests / future narrow streams).
    def subscribe_person(url, sub_id, pubkey)
      subscribe_home(url, sub_id, [pubkey])
    end

    # Replace the home filter in place: NIP-01 re-sending the same sub_id
    # swaps the relay's filter, so slot count and queue stay untouched.
    def refresh_home(url, sub_id, pubkeys, since: nil)
      return false unless @connections.key?(url) && (@live_subs[url] || []).include?(sub_id)

      filter = { authors: pubkeys, kinds: [1, 7, 1111] }
      filter[:since] = since if since
      transmit(url, NostrCore::Subscription.req(sub_id, filter))
      true
    end

    # Mentions/DM detection: our own NIP-65 inbox relays (separate stream A/B
    # rule). #p on a kind 1111 comment is the parent author, so comments on
    # our notes arrive here too. kinds is overridable — NIP-17 gift wraps
    # (kind 1059) ride the same sub without a second REQ slot.
    def subscribe_inbox(url, sub_id, my_pubkey, kinds: [1, 7, 1111])
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, { "#p": [my_pubkey], kinds: kinds }), false)
    end

    # NIP-46 bunker transport: requests arrive encrypted to us (kind 24133,
    # p-tagged to our pubkey). Persistent stream sub, like the inbox.
    def subscribe_bunker(url, sub_id, my_pubkey, since: nil)
      # priority: the signer's inbox must never wait behind seek storms or
      # the per-connection cap — a queued sub is invisible to NIP-46 clients.
      filter = { "#p": [my_pubkey], kinds: [24133] }
      # A fresh connection must NOT re-deliver days of kind-24133 history:
      # every replayed old request used to be re-answered (NIP-44 decrypt +
      # Schnorr sign + fan-out publish, each pure Ruby) — minutes of CPU at
      # every boot, on every relay, growing with history. Old requests are
      # dead anyway; NIP-46 clients retry when they still care.
      filter[:since] = since if since
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, filter), false, priority: true)
    end

    def seek_relay_list(url, sub_id, pubkey)
      queue_req(url, sub_id, NostrCore::Subscription.seek_relay_list(sub_id, pubkey), true)
    end

    def seek_profile(url, sub_id, pubkey)
      queue_req(url, sub_id, NostrCore::Subscription.seek_profile(sub_id, pubkey), true)
    end

    # Batched NIP-01 metadata sync: one REQ, many authors (kind 0).
    def seek_profiles(url, sub_id, pubkeys)
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, { authors: pubkeys, kinds: [0] }), true)
    end

    # Our own kind 3 contact list (follow merge source); one-shot like the
    # other seeks — CLOSED on the relay's EOSE.
    def seek_contact_list(url, sub_id, pubkey)
      queue_req(url, sub_id, NostrCore::Subscription.seek_contact_list(sub_id, pubkey), true)
    end

    def transmit_close(url, sub_id)
      transmit(url, NostrCore::Subscription.close(sub_id))
      req_finished(url, sub_id)
    end

    # True only when sub_id's REQ is actually in flight on a live connection.
    # Queued-but-not-started subs and dropped connections don't count —
    # callers re-issue until this turns true (bunker inbox self-heal).
    def sub_live?(url, sub_id)
      @connections.key?(url) && (@live_subs[url] || []).include?(sub_id)
    end

    # Publish a signed event to every connected relay (outbox refinement —
    # my NIP-65 write relays first — is a later pass). Returns urls sent to.
    def publish(event, urls: nil)
      frame = ["EVENT", event]
      @logger.puts "publish: frame=#{JSON.generate(frame)}"
      targets = urls || @connections.keys
      targets.each { |u| transmit(u, frame) }
      targets
    end

    def disconnect(url)
      drop(url, penalty: false)
    end

    private

    def transmit(url, frame)
      transport = @connections[url]
      return false unless transport

      transport.send_text(JSON.generate(frame))
      true
    end

    def handle_frame(url, data)
      msg = JSON.parse(data)
      case msg[0]
      when "AUTH"
        # NIP-42: relay demands auth -> reply ["AUTH", <signed kind 22242>].
        challenge = msg[1].is_a?(Hash) ? msg[1]["challenge"] : nil
        return unless challenge && @auth

        safe_call { transmit(url, ["AUTH", @auth.call(challenge, url)]) }
      when "EVENT" then safe_call { @on_event.call(url, msg[2]) }
      when "EOSE"
        # One-shot seeks (relay lists / profiles) are finished once the relay
        # says EOSE — leave them open and the relay keeps buffering for us.
        sub_id = msg[1]
        safe_call { @on_eose&.call(url, sub_id) }
        return unless @one_shot[url]&.delete(sub_id)

        transmit_close(url, sub_id)
        @logger.puts "eose: closed #{sub_id} @#{url.delete_prefix('wss://')}"
      when "OK"
        # NIP-01 publish ack: ["OK", event_id, accepted?, message]
        safe_call do
          if msg[2] == true
            @on_publish_result&.call(url, msg[1], true, msg[3])
          else
            @logger.puts "publish rejected by #{url}: #{msg[1][0, 8]} #{msg[3]}"
            @on_publish_result&.call(url, msg[1], false, msg[3])
          end
        end
      when "NOTICE" then @logger.puts "notice from #{url}: #{msg[1]}"
      end
    rescue JSON::ParserError
      nil
    end

    def drop(url, penalty:)
      transport = @connections.delete(url)
      transport&.close
      @one_shot.delete(url)
      @live_subs.delete(url) # slots die with the connection
      @queued.delete(url) # queued REQs die with the connection too
      safe_call { @on_disconnect.call(url, penalty ? @penalty_seconds : 0) }
    end

    # A relay politely limits concurrent subscriptions (nos.lol:
    # "too many concurrent REQs"). REQs beyond the per-connection cap queue
    # here and start FIFO as earlier subs CLOSE. One-shot seeks hold a slot
    # only until their EOSE; stream subs hold one until unsubscribed/dropped.
    # priority: true bypasses the cap and queue — reserved for the bunker
    # inbox (one REQ per relay), which clients depend on and must never be
    # starved behind seek storms or invisible while queued.
    def queue_req(url, sub_id, frame, one_shot, priority: false)
      if (@live_subs[url] || []).include?(sub_id)
        return true # already in flight; re-issuing would double-book the slot
      end
      if !priority && ((@live_subs[url] || []).size >= @max_subs || (@queued[url] || []).any?)
        (@queued[url] ||= []) << [sub_id, frame, one_shot]
        return true # accepted; starts when a slot frees
      end
      start_req(url, sub_id, frame, one_shot)
    end

    def start_req(url, sub_id, frame, one_shot)
      # Send first: a REQ that never reached the relay must not hold a slot
      # or count as live — queue/priority callers re-issue on a later tick.
      return false unless transmit(url, frame)
      one_shot(url, sub_id) if one_shot
      (@live_subs[url] ||= []) << sub_id
      true
    end

    # Free the slot of a finished REQ (CLOSE sent, or cancelled while queued)
    # and start queued REQs in FIFO order.
    def req_finished(url, sub_id)
      (@live_subs[url] || []).delete(sub_id)
      (@queued[url] || []).reject! { |id, _| id == sub_id }
      flush_queued(url)
    end

    def flush_queued(url)
      while (@live_subs[url] || []).size < @max_subs && (item = (@queued[url] || []).shift)
        start_req(url, *item)
      end
      @queued.delete(url) if @queued[url] && @queued[url].empty?
      @live_subs.delete(url) if @live_subs[url] && @live_subs[url].empty?
    end

    # A one-shot REQ: the pool CLOSEs it on the relay's EOSE, per relay, since
    # fan-out sends the same sub_id to several relays (each closes its own).
    def one_shot(url, sub_id)
      (@one_shot[url] ||= []) << sub_id unless @one_shot[url]&.include?(sub_id)
    end

    private

    # Client callbacks fire on EM/gem threads — a raising callback must not
    # kill the thread it runs on.
    def safe_call
      yield
    rescue StandardError => e
      @logger.puts "pool: callback error: #{e.class}: #{e.message}"
    end
  end

end
