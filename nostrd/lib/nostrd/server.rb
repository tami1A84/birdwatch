# frozen_string_literal: true

require "socket"
require "json"
require_relative "one_shot"

module Nostrd
  # NDJSON unix socket server. The TUI and the Rails PWA are both clients.
  # Protocol v0: see ../../docs/protocol.md
  class Server
    def initialize(store:, socket_path:, signer: ->(_name, _params) { true }, publisher: nil,
                   info: nil, relay_flags: nil, advertise_relays: nil, advertise_blossom: nil,
                   blossom_servers: nil, relay_remove: nil, lock: nil, unlock: nil, import_key: nil,
                   one_shot: nil, history: 100, bunker: nil,
                   follow: nil, unfollow: nil, send_dm: nil, dms: nil, blob_put: nil)
      @store = store
      @path = socket_path
      @signer = signer
      @publisher = publisher # signed events -> relays (nil = sign only)
      @blob_put = blob_put # path -> blossom upload result (mirror + public)
      @one_shot = one_shot # direct single-relay publish (Buzz Desktop's baked relay)
      @info = info # -> { "follows" => [...], "relays" => [{url, state}] }
      @relay_flags = relay_flags # gossip switches: {url:, read:, inbox:, write:, outbox:, discover:} -> flags
      @advertise_relays = advertise_relays # -> {relays: [...], event_id:, published_to: n}
      @advertise_blossom = advertise_blossom # -> {servers: [...], event_id:, published_to: n}
      @blossom_servers = blossom_servers # -> [url, ...]
      @relay_remove = relay_remove # url -> config removal
      @lock = lock # logout: lock the signer (passphrase to sign again)
      @unlock_op = unlock # passphrase -> signer.unlock
      @import_key = import_key # (nsec|hex, passphrase) -> create_key
      @history = history # default timeline replay size (--history); a client
      # may still pass params.limit to override per subscription
      @follow = follow # pubkey -> orchestrator.follow (state + dial)
      @unfollow = unfollow # pubkey -> orchestrator.unfollow
      @send_dm = send_dm # (pubkey, text) -> {"event_id"=>, "published_to"=>} (Nostrd::Dm)
      @dms = dms # (partner:, limit:) -> {"events"=>[...]} | {"conversations"=>[...]}
      @bunker = bunker # Nostrd::Bunker (nil = NIP-46 transport disabled)
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
      when "advertise_blossom" then advertise_blossom(conn, msg)
      when "blossom_servers" then blossom_servers_op(conn, msg)
      when "blossom_set" then blossom_set_op(conn, msg)
      when "announce_repo" then announce_repo(conn, msg)
      when "follow" then follow_op(conn, msg)
      when "unfollow" then unfollow_op(conn, msg)
      when "send_dm" then send_dm_op(conn, msg)
      when "blob_put" then blob_put_op(conn, msg)
      when "delete_note" then delete_note_op(conn, msg)
      when "search" then search_op(conn, msg)
      when "bunker_secret" then bunker_secret_op(conn, msg)
      when "bunker_list" then bunker_list_op(conn, msg)
      when "bunker_forget" then bunker_forget_op(conn, msg)
      when "sign_raw" then sign_raw_op(conn, msg)
      when "publish_raw" then publish_raw_op(conn, msg)
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
      when "dms"
        dms_channel(conn, msg)
      else
        reply(conn, ev: "error", code: "unknown_channel", message: msg["channel"].to_s)
      end
    end

    # Channel "dms": stored kind-14 chat history. partner given = one thread
    # as event frames; omitted = conversation list — then eod, following the
    # profiles/eod replay pattern (no live listener registration).
    def dms_channel(conn, msg)
      p = msg.dig("params") || {}
      out = @dms&.call(partner: p["partner"], limit: p["limit"]) || {}
      Array(out["events"]).each { |e| reply(conn, ev: "event", sub: msg["id"], event: e) }
      if out["conversations"]
        reply(conn, ev: "conversations", sub: msg["id"], conversations: out["conversations"])
      end
      reply(conn, ev: "eod", sub: msg["id"])
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
            blossom: data["blossom"] || data[:blossom] || [],
            profiles: data["profiles"] || data[:profiles] || [],
            bunker: { "enabled" => @bunker&.enabled? || false,
                      "sessions" => @bunker ? @bunker.session_pubkeys : [] })
    rescue StandardError => e
      reply(conn, ev: "error", id: id, code: "info_failed", message: e.message)
    end

    def lookup(conn, msg)
      params = msg.dig("params") || {}
      case msg["kind"]
      when "note"
        return note_lookup(conn, msg, params)
      when "author"
        return author_lookup(conn, msg, params)
      when "profile"
        return profile_lookup(conn, msg, params)
      end

      event = @store.find_event(msg.dig("params", "id").to_s)
      if event
        reply(conn, ev: "result", id: msg["id"], data: event.to_h)
      else
        reply(conn, ev: "error", id: msg["id"], code: "not_found", message: "no such event")
      end
    end

    # kind "note": flat event, or scope:"thread" = note + its NIP-22
    # comments (kind 1111, root "E" tag) + NIP-25 reactions (kind 7).
    def note_lookup(conn, msg, params)
      id = params["id"].to_s
      event = @store.find_event(id)
      unless event
        reply(conn, ev: "error", id: msg["id"], code: "not_found", message: "no such event")
        return
      end

      if params["scope"] == "thread"
        reply(conn, ev: "result", id: msg["id"],
                   data: { "note" => event.to_h,
                           "comments" => @store.find_comments(id).map(&:to_h),
                           "reactions" => @store.find_reactions(id).map(&:to_h) })
      else
        reply(conn, ev: "result", id: msg["id"], data: event.to_h)
      end
    end

    # kind "author": a pubkey's kind-1 notes, newest first.
    def author_lookup(conn, msg, params)
      pubkey = params["pubkey"].to_s
      unless pubkey.match?(/\A[0-9a-f]{64}\z/)
        reply(conn, ev: "error", id: msg["id"], code: "bad_request", message: "pubkey must be 64 hex chars")
        return
      end

      limit = (params["limit"] || 50).to_i.clamp(1, 200)
      notes = @store.timeline_by_author(pubkey, limit: limit)
      reply(conn, ev: "result", id: msg["id"], data: { "notes" => notes.map(&:to_h) })
    end

    # kind "profile": stored kind-0 metadata for one pubkey (or null).
    def profile_lookup(conn, msg, params)
      pubkey = params["pubkey"].to_s
      profile = @store.profile_for(pubkey)
      reply(conn, ev: "result", id: msg["id"], data: { "profile" => profile })
    end

    def act(conn, msg)
      # Signing oracle boundary: clients send actions, never raw events.
      # NIP-46 bunker gate: when the bunker is enabled, an action MAY carry
      # "client" (the NIP-46 client pubkey); if present it must name an
      # active bunker session. Clients that pass no client field (the TUI)
      # keep their trusted-local behavior — the gate exists so the web can
      # make every write attributable to an authenticated bunker session.
      if @bunker&.enabled? && msg["client"]
        client = msg["client"].to_s
        raise ArgumentError, "no_session" unless
          client.match?(/\A[0-9a-f]{64}\z/) && @bunker.active?(client)
      end

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

    # Blossom server list (NIP-B7): publish the current list as kind 10063.
    def advertise_blossom(conn, msg)
      out = @advertise_blossom&.call || {}
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: out["event_id"], servers: out["servers"] || [],
                 published_to: out["published_to"] || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Current blossom list (override file → published event → defaults).
    def blossom_servers_op(conn, msg)
      urls = @blossom_servers&.call || []
      reply(conn, ev: "result", id: msg["id"], ok: true, data: { "servers" => urls })
    rescue StandardError => e
      reply(conn, ev: "result", id: msg["id"], ok: false, error: e.message)
    end

    # Persist an edited list to ~/.config/nostrd/blossom.json (the daemon
    # picks it up as the source of truth for uploads and publishing).
    def blossom_set_op(conn, msg)
      urls = Array(msg.dig("params", "servers")).map { |u| u.to_s.delete_suffix("/") }
                                              .select { |u| u.match?(%r{\Ahttps?://\S+\z}) }.uniq
      raise ArgumentError, "blossom_set needs servers [url]" if urls.empty?

      file = File.expand_path("~/.config/nostrd/blossom.json")
      dir = File.dirname(file)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      File.write(file, JSON.generate(urls))
      reply(conn, ev: "ack", id: msg["id"], ok: true, servers: urls)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # --- web client ops (follows, deletions, search) --------------------

    # NIP-17: sign + publish a gift-wrapped kind-14 rumor to the recipient's
    # inbox relays. The Dm service owns the protocol; the daemon owns the
    # keys — clients send intent (pubkey + text), never events.
    # b op: upload a local file to blossom — embedded mirror first, then
    # public servers (NIP-98 auth signed by the daemon key). The result
    # carries the canonical URL (first public hit, local fallback).
    def blob_put_op(conn, msg)
      raise ArgumentError, "blob service is not wired" unless @blob_put

      out = @blob_put.call(msg.dig("params", "path").to_s) || {}
      reply(conn, ev: "result", id: msg["id"], ok: true, data: out)
    rescue ArgumentError => e
      reply(conn, ev: "result", id: msg["id"], ok: false, error: e.message)
    end

    def send_dm_op(conn, msg)
      p = msg["params"] || {}
      raise ArgumentError, "send_dm needs text" if p["text"].to_s.empty?

      out = @send_dm&.call(p["pubkey"].to_s, p["text"]) || {}
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: out["event_id"], published_to: out["published_to"] || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Follow: orchestrator state + store, then republish the contact list
    # (kind 3) so relays learn about the change.
    def follow_op(conn, msg)
      pk = msg.dig("params", "pubkey").to_s
      unless pk.match?(/\A[0-9a-f]{64}\z/)
        reply(conn, ev: "error", id: msg["id"], code: "bad_request",
                   message: "pubkey must be 64 hex chars")
        return
      end

      @follow&.call(pk)
      event, published = republish_contacts
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: event && event[:id], published_to: published&.size || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    def unfollow_op(conn, msg)
      pk = msg.dig("params", "pubkey").to_s
      unless pk.match?(/\A[0-9a-f]{64}\z/)
        reply(conn, ev: "error", id: msg["id"], code: "bad_request",
                   message: "pubkey must be 64 hex chars")
        return
      end

      @unfollow&.call(pk)
      event, published = republish_contacts
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: event && event[:id], published_to: published&.size || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # NIP-09: sign kind 5 for the stored events, publish, then purge them
    # from the store. Unknown ids are skipped (nothing to look up).
    def delete_note_op(conn, msg)
      ids = Array(msg.dig("params", "ids")).map(&:to_s).select do |id|
        id.match?(/\A[0-9a-f]{64}\z/)
      end
      if ids.empty?
        reply(conn, ev: "error", id: msg["id"], code: "bad_request",
                   message: "ids must be 64-hex event ids")
        return
      end

      targets = ids.filter_map do |id|
        (ev = @store.find_event(id)) ? { "id" => id, "kind" => ev.kind } : nil
      end
      event = nil
      published = nil
      if targets.any?
        event = @signer.call("delete_note", { "targets" => targets })
        published = @publisher&.call(event)
      end
      deleted = @store.purge_events(targets.map { |t| t["id"] })
      reply(conn, ev: "ack", id: msg["id"], ok: true,
                 event_id: event && event[:id], deleted: deleted,
                 published_to: published&.size || 0)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Full-store search: cached notes/comments by content, profiles by
    # name/display_name/nip05/pubkey prefix.
    def search_op(conn, msg)
      query = msg.dig("params", "query").to_s.strip
      if query.empty?
        reply(conn, ev: "error", id: msg["id"], code: "bad_request", message: "query is empty")
        return
      end

      limit = (msg.dig("params", "limit") || 50).to_i.clamp(1, 200)
      notes, profiles = @store.search(query, limit: limit)
      reply(conn, ev: "result", id: msg["id"],
                 data: { "notes" => notes.map(&:to_h), "profiles" => profiles })
    rescue StandardError => e
      reply(conn, ev: "error", id: msg["id"], code: "search_failed", message: e.message)
    end

    # --- NIP-46 bunker ops ----------------------------------------------

    # Mint/return the bunker connection material: creates bunker.json with a
    # fresh secret on first use, never rotates an existing one.
    def bunker_secret_op(conn, msg)
      raise ArgumentError, "bunker unavailable" unless @bunker

      info = @bunker.enable
      reply(conn, ev: "result", id: msg["id"], data: info)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Raw-sign a vetted event (kind allowlist lives in Signer#sign_raw) for
    # local flows the action vocabulary does not cover: Blossom NIP-98 auth,
    # NIP-5A nsite manifests. Reply carries the full signed event.
    def sign_raw_op(conn, msg)
      event = @signer.call("sign_raw", msg["params"] || {})
      reply(conn, ev: "result", id: msg["id"], data: { "event" => event })
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # sign_raw + hand the signed event to the publisher (relays) — nsite
    # manifest updates. params.urls optionally restricts the target relays
    # (the publisher lambda fans out to every connected relay by default).
    def publish_raw_op(conn, msg)
      event = @signer.call("sign_raw", msg["params"] || {})
      raise ArgumentError, "daemon is not live (no relay publisher)" unless @publisher

      published = @publisher.call(event)
      reply(conn, ev: "result", id: msg["id"],
                 data: { "event" => event, "published_to" => published })
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    def bunker_list_op(conn, msg)
      raise ArgumentError, "bunker unavailable" unless @bunker

      reply(conn, ev: "result", id: msg["id"],
                 data: { "clients" => @bunker.clients,
                         "sessions" => @bunker.session_pubkeys,
                         "enabled" => @bunker.enabled? })
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Drop a client from the allowlist and kill its live session.
    def bunker_forget_op(conn, msg)
      raise ArgumentError, "bunker unavailable" unless @bunker

      client = msg.dig("params", "client").to_s
      raise ArgumentError, "client must be 64 hex chars" unless client.match?(/\A[0-9a-f]{64}\z/)

      removed = @bunker.forget!(client)
      reply(conn, ev: "ack", id: msg["id"], ok: true, forgotten: removed == client)
    rescue StandardError => e
      reply(conn, ev: "ack", id: msg["id"], ok: false, error: e.message)
    end

    # Kind 3 contact list reflecting the CURRENT follow set (info callable
    # serves the same source of truth as the orchestrator).
    def republish_contacts
      follows = @info&.call&.[]("follows") || []
      event = @signer.call("update_contacts", { "pubkeys" => follows })
      published = @publisher&.call(event)
      [event, published]
    end

    def reply(conn, hash)
      conn.puts(JSON.generate(hash))
    rescue IOError, Errno::EPIPE
      nil
    end
  end
end
