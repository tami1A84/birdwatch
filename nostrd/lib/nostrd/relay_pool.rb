# frozen_string_literal: true

require "json"
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
      @one_shot = {} # url => [sub_ids] — seeks are done after their EOSE
      @live_subs = {} # url => [sub_ids] — REQs actually sent (occupy a slot)
      @queued = {} # url => [[sub_id, frame, one_shot?]] — waiting for a slot
    end

    attr_reader :connections

    # NIP-42 wiring: block returns the signed auth event for a challenge.
    def auth_with(&block)
      @auth = block
    end

    def connect(url)
      return if @connections.key?(url)

      klass = @transport_class
      unless klass
        require_relative "ws_client" # lazy: pulls socket/openssl stack
        klass = Nostrd::WsTransport  # v2: single mux reader thread for all conns
      end
      transport = klass.new(url)
      transport.on_message { |data| handle_frame(url, data) }
      transport.on_close { drop(url, penalty: true) }
      transport.open
      @connections[url] = transport
      @logger.puts "pool: connected #{url}"
      url
    rescue StandardError => e
      @logger.puts "pool: #{url} failed: #{e.class}"
      drop(url, penalty: true)
      nil
    end

    # Stream a person's notes from one assigned relay (RelayPicker's assignment).
    # NOTE: no limit key — strfry treats limit:0 as "zero events".
    # One batched home stream per relay: every person in a single REQ. The
    # old per-person fan-out (1 REQ each) starved the pool's per-connection
    # cap of 8 — once follows outgrew 8, every new stream queued forever and
    # the home feed froze at whatever history was cached at startup.
    def subscribe_home(url, sub_id, pubkeys)
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, { authors: pubkeys, kinds: [1, 7, 1111] }), false)
    end

    # Single-author stream (kept for tests / future narrow streams).
    def subscribe_person(url, sub_id, pubkey)
      subscribe_home(url, sub_id, [pubkey])
    end

    # Replace the home filter in place: NIP-01 re-sending the same sub_id
    # swaps the relay's filter, so slot count and queue stay untouched.
    def refresh_home(url, sub_id, pubkeys)
      return false unless @connections.key?(url) && (@live_subs[url] || []).include?(sub_id)

      transmit(url, NostrCore::Subscription.req(sub_id, { authors: pubkeys, kinds: [1, 7, 1111] }))
      true
    end

    # Mentions/DM detection: our own NIP-65 inbox relays (separate stream A/B
    # rule). #p on a kind 1111 comment is the parent author, so comments on
    # our notes arrive here too.
    def subscribe_inbox(url, sub_id, my_pubkey)
      queue_req(url, sub_id, NostrCore::Subscription.req(sub_id, { "#p": [my_pubkey], kinds: [1, 7, 1111] }), false)
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
    def queue_req(url, sub_id, frame, one_shot)
      if (@live_subs[url] || []).size >= @max_subs || (@queued[url] || []).any?
        (@queued[url] ||= []) << [sub_id, frame, one_shot]
        return true # accepted; starts when a slot frees
      end
      start_req(url, sub_id, frame, one_shot)
    end

    def start_req(url, sub_id, frame, one_shot)
      one_shot(url, sub_id) if one_shot
      (@live_subs[url] ||= []) << sub_id
      transmit(url, frame)
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
