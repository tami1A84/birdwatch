# frozen_string_literal: true

require "socket"
require "json"
require_relative "one_shot"

module Nostrd
  # NDJSON unix socket server. The TUI and the Rails PWA are both clients.
  # Protocol v0: see ../../docs/protocol.md
  class Server
    def initialize(store:, socket_path:, signer: ->(_name, _params) { true }, publisher: nil,
                   info: nil, relay_flags: nil, advertise_relays: nil, relay_remove: nil, lock: nil, unlock: nil, import_key: nil,
                   one_shot: nil, history: 100)
      @store = store
      @path = socket_path
      @signer = signer
      @publisher = publisher # signed events -> relays (nil = sign only)
      @one_shot = one_shot # direct single-relay publish (Buzz Desktop's baked relay)
      @info = info # -> { "follows" => [...], "relays" => [{url, state}] }
      @relay_flags = relay_flags # gossip switches: {url:, read:, inbox:, write:, outbox:, discover:} -> flags
      @advertise_relays = advertise_relays # -> {relays: [...], event_id:, published_to: n}
      @relay_remove = relay_remove # url -> config removal
      @lock = lock # logout: lock the signer (passphrase to sign again)
      @unlock_op = unlock # passphrase -> signer.unlock
      @import_key = import_key # (nsec|hex, passphrase) -> create_key
      @history = history # default timeline replay size (--history); a client
      # may still pass params.limit to override per subscription
      @listeners = [] # timeline subscriber conns for live broadcast
      @mos = Mutex.new
    end

    # Push a fresh event to every live timeline subscriber. Called by the
    # wiring for our own publishes and for relay-arrived kind 1 events.
    # TUI clients dedupe by event id, so an echo of an already-sent event
    # (relay replaying our own post back) is harmless.
    def broadcast_event(event_hash)
      write_listeners(JSON.generate(ev: "event", sub: "live", event: event_hash))
      # Author label for fresh arrivals (mirrors the history path's profiles
      # frame); skipped silently when no metadata is known yet.
      return unless event_hash.is_a?(Hash) && event_hash["pubkey"]

      push_profile(event_hash["pubkey"])
    end

    # Push an author's stored profile to live subscribers. Called whenever a
    # kind 0 lands in the store (seek result) so names appear WITHOUT the
    # client having to reconnect; skipped while there is nothing to show.
    def broadcast_profile(pubkey)
      push_profile(pubkey)
    end

    def run
      File.unlink(@path) if File.exist?(@path)
      srv = UNIXServer.new(@path)
      File.chmod(0600, @path)
      warn "nostrd listening on #{@path}"
      loop { Thread.new(srv.accept) { |conn| handle(conn) } }
    end

    def handle(conn)
      conn.each_line do |line|
        line = line.strip
        next if line.empty?

        msg = safe_parse(line)
        if msg.nil?
          reply(conn, ev: "error", code: "bad_json", message: "unparsable line")
          next
        end
        dispatch(conn, msg)
      end
    ensure
      @mos.synchronize { @listeners.delete(conn) }
      begin
        conn.close
      rescue IOError, Errno::EPIPE
        nil
      end
    end

    private

    # Send a frame to every live subscriber, pruning dead connections.
    def write_listeners(frame)
      listeners = @mos.synchronize { @listeners.dup }
      dead = []
      listeners.each do |conn|
        begin
          conn.puts(frame)
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET, SystemCallError
          dead << conn
        end
      end
      @mos.synchronize { @listeners -= dead } unless dead.empty?
    end

    # Push an author's stored profile to live subscribers (kind 0 arrivals:
    # seek results) so names update without the client reconnecting. Skipped
    # while there is nothing to show.
    def push_profile(pubkey)
      profile = @store.profile_for(pubkey)
      return unless profile &&
                    profile.values_at("name", "display_name", "nip05", "picture", "about").any?

      write_listeners(JSON.generate(ev: "profiles", sub: "live", profiles: [profile]))
    end

    def safe_parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def dispatch(conn, msg)
      case msg["op"]
      when "hello" then reply(conn, ev: "hello", proto: 1)
      when "ping" then reply(conn, ev: "pong")
      when "sub" then subscribe(conn, msg)
      when "unsub" then true # v0: streams die with the connection
      when "get" then lookup(conn, msg)
      when "profiles" then send_profiles(conn, sub: nil, limit: msg.dig("params", "limit"))
      when "info" then send_info(conn, msg["id"])
      when "action" then act(conn, msg)
      when "lock" then lock(conn, msg)
      when "unlock" then unlock_op(conn, msg)
      when "import_key" then import_key_op(conn, msg)
      when "relay_flags" then relay_flags(conn, msg)
      when "relay_remove" then relay_remove(conn, msg)
      when "advertise_relays" then advertise_relays(conn, msg)
      when "announce_repo" then announce_repo(conn, msg)
      else reply(conn, ev: "error", code: "unknown_op", message: msg["op"].to_s)
      end
    end

    def subscribe(conn, msg)
      case msg["channel"]
      when "timeline"
        events = @store.timeline(limit: msg.dig("params", "limit") || @history)
        events.each do |event|
          reply(conn, ev: "event", sub: msg["id"], event: event.to_h)
        end
        send_profiles(conn, sub: msg["id"], for_events: events)
        reply(conn, ev: "eod", sub: msg["id"])
        @mos.synchronize { @listeners << conn unless @listeners.include?(conn) }
      else
        reply(conn, ev: "error", code: "unknown_channel", message: msg["channel"].to_s)
      end
    end

    # kind 0 metadata for the authors on screen; sent after history, before eod.
    def send_profiles(conn, sub:, for_events: nil, limit: nil)
      pks = if for_events
        for_events.map(&:pubkey).uniq
      else
        @store.timeline(limit: limit || @history).map(&:pubkey).uniq
      end
      profiles = @store.profiles_for(pks).values
      return if profiles.empty?

      frame = { ev: "profiles", profiles: profiles }
      frame[:sub] = sub if sub
      reply(conn, frame)
    end

    # SSS header data: follows + currently dialed relays.
    def send_info(conn, id)
      data = @info&.call || {}
      reply(conn, ev: "info", id: id,
            follows: data["follows"] || data[:follows] || [],
            me: data["me"] || data[:me],
            my_profile: data["my_profile"] || data[:my_profile],
            locked: data["locked"] || data[:locked] || false,
            relays: data["relays"] || data[:relays] || [],
            profiles: data["profiles"] || data[:profiles] || [])
    rescue StandardError => e
      reply(conn, ev: "error", id: id, code: "info_failed", message: e.message)
    end

    def lookup(conn, msg)
      event = @store.find_event(msg.dig("params", "id").to_s)
      if event
        reply(conn, ev: "result", id: msg["id"], data: event.to_h)
      else
        reply(conn, ev: "error", id: msg["id"], code: "not_found", message: "no such event")
      end
    end

    def act(conn, msg)
      # Signing oracle boundary: clients send actions, never raw events.
      event = @signer.call(msg["name"], msg["params"] || {})
      published = @publisher && event.is_a?(Hash) ? @publisher.call(event) : nil
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: event.is_a?(Hash) ? event[:id] : nil,
                 published_to: published&.size || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # NIP-34 repo announcement -> Buzz Desktop Projects view. The app reads
    # a single baked relay (VITE_RELAY_URL), so this publishes DIRECTLY to
    # params["relay"] (default: Buzz's public relay) instead of the gossip
    # pool. One NIP-42 AUTH challenge is answered via the signer.
    def announce_repo(conn, msg)
      event = @signer.call("announce_repo", msg["params"] || {})
      url = msg.dig("params", "relay") || "wss://png.communities.buzz.xyz"
      auth = @signer.respond_to?(:auth_event) ? ->(challenge) { @signer.auth_event(challenge, url) } : nil
      ok, message = (@one_shot || Nostrd::OneShot).publish(url, event, auth: auth)
      reply(conn, ev: "ack", id: msg["id"], ok: ok,
                 event_id: event.is_a?(Hash) ? event[:id] : nil,
                 relay: url, message: message)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Logout: lock the signer — every signing action refuses until the
    # vault passphrase unlocks it again.
    def lock(conn, msg)
      @lock&.call
      reply(conn, ev: "ack", id: msg["id"], ok: true, locked: true)
    end

    # Unlock: vault passphrase in, signer ready. The passphrase rides the
    # unix socket (0600, same user) — never logged, never echoed.
    def unlock_op(conn, msg)
      @unlock_op&.call(msg.dig("params", "passphrase").to_s)
      reply(conn, ev: "ack", id: msg["id"], ok: true, locked: false)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Import: nsec (nsec1… or 64-hex) + passphrase -> re-encrypt the vault
    # and unlock with the new identity. Orchestrator identity refreshes on
    # the next daemon restart.
    def import_key_op(conn, msg)
      p = msg["params"] || {}
      id = @import_key&.call(p["key"].to_s, p["passphrase"].to_s)
      reply(conn, ev: "ack", id: msg["id"], ok: true, pubkey: id && id[:pubkey])
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Gossip-style relay switches: local-only change, no publication. The
    # wiring lambda (orchestrator) merges dependencies (inbox=>read etc.).
    def relay_flags(conn, msg)
      p = msg["params"] || {}
      raise ArgumentError, "relay_flags needs a ws url" unless p["url"].to_s.start_with?("ws")

      flags = @relay_flags&.call(p) || p
      reply(conn, ev: "ack", id: msg["id"], ok: true, flags: flags)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # TUI relay management: delete the configured relay (config only; the
    # connection, if any, drops naturally on the next tick).
    def relay_remove(conn, msg)
      url = msg.dig("params", "url").to_s
      raise ArgumentError, "relay_remove needs a ws url" unless url.start_with?("ws")

      @relay_remove&.call(url)
      reply(conn, ev: "ack", id: msg["id"], ok: true, url: url)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Advertise Relay List (gossip): sign + publish kind 10002 from the
    # local switch state. One press = one publication.
    def advertise_relays(conn, msg)
      out = @advertise_relays&.call || {}
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: out["event_id"], relays: out["relays"] || [],
                 published_to: out["published_to"] || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    def reply(conn, hash)
      conn.puts(JSON.generate(hash))
    rescue IOError, Errno::EPIPE
      nil
    end
  end
end
