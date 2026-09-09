# frozen_string_literal: true

require "socket"
require "json"
require "digest"
require "websocket"
require_relative "../nostr_core/event"
require_relative "../nostr_core/bip340"

module Nostrd
  # Embedded personal relay (chorus-style): a loopback NIP-01 endpoint over
  # the SAME SQLite store the daemon uses. Local clients (TUI, PWA, scripts)
  # speak plain Nostr WebSocket instead of the NDJSON unix-socket protocol.
  # Server-side framing mirrors WsMux (ws_client.rb) with roles flipped:
  # client frames arrive MASKED, ours go out plain. Loopback-only by
  # default — the allowlist is the second gate when exposed further.
  class LocalRelay
    LIMIT_DEFAULT = 500 # REQ limit when the client sends none
    LIMIT_MAX = 1000    # cap so one REQ cannot drain the whole store
    HANDSHAKE_TIMEOUT = 5 # seconds for the HTTP upgrade, then blocking I/O

    attr_reader :host, :port, :allowed_pubkeys

    # Relay-pool dial target (ws:// plaintext, loopback only).
    def url = "ws://#{@host}:#{@port}"

    def initialize(store:, port: 7777, host: "127.0.0.1", allowed_pubkeys: [], logger: $stderr)
      @store = store
      @host = host
      @port = port
      # Personal relay rule: empty allowlist = open (fine on 127.0.0.1).
      @allowed = allowed_pubkeys.map { |pk| pk.to_s.downcase }
      @logger = logger
      @conns = [] # live Conn objects
      @mos = Mutex.new
      @server = nil
      @thread = nil
      @stopping = false
    end

    # Binds synchronously so callers can read #port right after (port: 0
    # resolves to the ephemeral port the test client dials), then accepts in
    # a background thread — one thread per connection, like Server#run.
    def start
      @stopping = false
      @server = TCPServer.new(@host, @port)
      @port = @server.addr[1]
      @thread = Thread.new do
        Thread.current.name = "local-relay" if Thread.current.respond_to?(:name=)
        srv = @server # local copy: #stop nils @server mid-loop
        loop do
          break if @stopping
          # 0.5s poll: a blocked accept() is not reliably woken by close()
          # on every platform, so #stop must be able to win the race.
          next unless IO.select([srv], nil, nil, 0.5)

          begin
            sock = srv.accept
          rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED
            next
          end
          Thread.new(sock) { |s| serve(s) }
        end
      rescue IOError, SystemCallError
        nil # listener closed by #stop — normal shutdown
      end
      self
    end

    def stop
      @stopping = true
      srv, th = @server, @thread
      @server = nil
      @thread = nil
      srv&.close rescue nil # unblocks the accept() with IOError
      th&.join(2)
      conns = @mos.synchronize { @conns.dup }
      conns.each(&:close) # closing sockets unblocks the reader threads
      true
    end

    def running? = !@server.nil?

    private

    def serve(sock)
      sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil
      handshake!(sock)
      return if @stopping

      conn = Conn.new(sock)
      @mos.synchronize { @conns << conn }
      frames = WebSocket::Frame::Incoming::Server.new(version: 13)
      loop do
        frames << sock.readpartial(65_536)
        while (frame = frames.next)
          case frame.type
          when :ping then conn.send_frame(pong_for(frame))
          when :close
            conn.send_frame(WebSocket::Frame::Outgoing::Server.new(type: :close, version: 13).to_s)
            return
          when :text then handle_message(conn, frame.data.to_s)
          end # :binary and :pong ignored — NIP-01 traffic is text only
        end
      end
    rescue StandardError => e
      # Client vanished mid-frame or sent garbage: scoped to this connection.
      log("conn dropped: #{e.class}: #{e.message}") unless e.is_a?(EOFError)
    ensure
      @mos.synchronize { @conns.delete(conn) } if conn
      sock.close rescue nil
    end

    # HTTP upgrade. IO timeout during the handshake only, so a silent or
    # garbage TCP client cannot park a thread forever; lifted afterwards
    # because an idle subscription (hours without traffic) is valid here.
    def handshake!(sock)
      sock.timeout = HANDSHAKE_TIMEOUT if sock.respond_to?(:timeout=)
      hs = WebSocket::Handshake::Server.new
      hs << sock.readpartial(4096) until hs.finished?
      raise WebSocket::Error, "invalid websocket handshake" unless hs.valid?

      sock.write(hs.to_s)
      sock.timeout = nil if sock.respond_to?(:timeout=)
    end

    # Per-message rescue: one bad frame must never kill the connection
    # thread (same discipline as RelayPool#safe_call).
    def handle_message(conn, raw)
      msg = JSON.parse(raw)
      unless msg.is_a?(Array) && msg[0].is_a?(String)
        return notice(conn, "invalid: message must be a JSON array with a string type")
      end

      case msg[0]
      when "EVENT" then handle_event(conn, msg)
      when "REQ" then handle_req(conn, msg)
      when "CLOSE" then conn.drop_sub(msg[1].to_s) # NIP-01: CLOSE has no reply
      else notice(conn, "invalid: unsupported message type #{msg[0]}")
      end
    rescue JSON::ParserError
      notice(conn, "invalid: message is not valid JSON")
    rescue StandardError => e
      log("message error: #{e.class}: #{e.message}")
      notice(conn, "error: handler failed")
    end

    def handle_event(conn, msg)
      ev = msg[1]
      ok, message, stored = accept_event(ev)
      broadcast(stored) if stored # duplicates must not echo to live subs
      reply_ok(conn, ev, ok, message)
    end

    # Validation ladder: shape -> id hash -> signature -> allowlist. Returns
    # [ok, message, stored_event]; stored_event is nil for duplicates (the
    # idempotent OK-true path) and for rejects.
    def accept_event(ev)
      return [false, "invalid: event must be an object", nil] unless ev.is_a?(Hash)

      id = ev["id"].to_s
      pubkey = ev["pubkey"].to_s
      sig = ev["sig"].to_s
      return [false, "invalid: id must be 64 hex chars", nil] unless id.match?(/\A[0-9a-f]{64}\z/)
      return [false, "invalid: pubkey must be 64 hex chars", nil] unless pubkey.match?(/\A[0-9a-f]{64}\z/)
      return [false, "invalid: sig must be 128 hex chars", nil] unless sig.match?(/\A[0-9a-f]{128}\z/)
      return [false, "invalid: created_at must be an integer", nil] unless ev["created_at"].is_a?(Integer)
      return [false, "invalid: kind must be an integer", nil] unless ev["kind"].is_a?(Integer)
      return [false, "invalid: content must be a string", nil] unless ev["content"].is_a?(String)
      return [false, "invalid: tags must be arrays of strings", nil] unless valid_tags?(ev["tags"])

      expected = Digest::SHA256.hexdigest(
        NostrCore::Event.id_payload(pubkey, ev["created_at"], ev["kind"], ev["tags"], ev["content"])
      )
      return [false, "invalid: id does not match the NIP-01 serialization", nil] unless expected == id

      unless NostrCore::Bip340.verify([pubkey].pack("H*"), [id].pack("H*"), [sig].pack("H*"))
        return [false, "invalid: signature verification failed", nil]
      end

      return [false, "blocked: pubkey is not allowed on this relay", nil] unless allowed?(pubkey)
      return [true, "duplicate:", nil] if @store.find_event(id)

      @store.upsert_event(NostrCore::Event.new(id: id, pubkey: pubkey, created_at: ev["created_at"],
                                               kind: ev["kind"], content: ev["content"], tags: ev["tags"]))
      [true, "", canonical(ev)]
    end

    def valid_tags?(tags)
      tags.is_a?(Array) && tags.all? { |t| t.is_a?(Array) && t.all? { |v| v.is_a?(String) } }
    end

    def allowed?(pubkey)
      @allowed.empty? || @allowed.include?(pubkey)
    end

    def reply_ok(conn, ev, ok, message)
      conn.send_text(JSON.generate(["OK", ev.is_a?(Hash) ? ev["id"].to_s : "", ok, message]))
    end

    def handle_req(conn, msg)
      sub_id = msg[1].to_s
      filters = msg[2..]
      if sub_id.empty? || !filters.is_a?(Array) || filters.empty? || !filters.all?(Hash)
        return notice(conn, "invalid: REQ needs a sub id and at least one filter object")
      end

      norm = filters.map { |f| normalize_filter(f) }
      conn.set_sub(sub_id, norm) # NIP-01: a REQ with the same sub id replaces it
      @store.relay_query(norm).each do |event|
        conn.send_text(JSON.generate(["EVENT", sub_id, event_json(event)]))
      end
      conn.send_text(JSON.generate(["EOSE", sub_id]))
      conn.mark_live(sub_id) # live push only once the initial stream is done
    end

    # Client filter (NIP-01 string keys) -> the normalized hash that
    # relay_query and the live matcher both consume.
    def normalize_filter(f)
      {
        "ids" => hex64(f["ids"]),
        "authors" => hex64(f["authors"]),
        "kinds" => Array(f["kinds"]).select { |k| k.is_a?(Integer) },
        "since" => f["since"].is_a?(Integer) ? f["since"] : nil,
        "until" => f["until"].is_a?(Integer) ? f["until"] : nil,
        "e" => tag_values(f["#e"]),
        "p" => tag_values(f["#p"]),
        "a" => tag_values(f["#a"]),
        "limit" => (f["limit"] || LIMIT_DEFAULT).to_i.clamp(1, LIMIT_MAX)
      }
    end

    def hex64(list)
      Array(list).select { |v| v.is_a?(String) && v.match?(/\A[0-9a-f]{64}\z/) }
    end

    def tag_values(list)
      Array(list).select { |v| v.is_a?(String) && !v.empty? }
    end

    # Wire form of a STORED event. The store does not persist signatures, so
    # REQ replays carry no "sig"; fresh broadcasts do (see canonical).
    def event_json(event)
      { "id" => event.id, "pubkey" => event.pubkey, "created_at" => event.created_at,
        "kind" => event.kind, "content" => event.content, "tags" => event.tags }
    end

    # Wire form of a freshly verified event: known fields only, plus the sig.
    def canonical(ev)
      h = { "id" => ev["id"], "pubkey" => ev["pubkey"], "created_at" => ev["created_at"],
            "kind" => ev["kind"], "content" => ev["content"], "tags" => ev["tags"] }
      h["sig"] = ev["sig"] if ev["sig"]
      h
    end

    # Live push (NIP-01: a stored event fans out to every matching sub on
    # every connection). Best-effort: a slow or dying socket just skips its
    # frame — its read loop notices EOF on the next pass.
    def broadcast(ev)
      conns = @mos.synchronize { @conns.dup }
      conns.each do |conn|
        conn.each_live_sub do |sub_id, filters|
          next unless filters.any? { |f| matches?(f, ev) }

          conn.send_text(JSON.generate(["EVENT", sub_id, ev]))
        end
      end
    rescue StandardError => e
      log("broadcast error: #{e.class}: #{e.message}")
    end

    # Ruby twin of relay_query's SQL for the live path (single event, no DB).
    def matches?(f, ev)
      return false unless f["ids"].empty? || f["ids"].include?(ev["id"])
      return false unless f["authors"].empty? || f["authors"].include?(ev["pubkey"])
      return false unless f["kinds"].empty? || f["kinds"].include?(ev["kind"])
      return false if f["since"] && ev["created_at"] < f["since"]
      return false if f["until"] && ev["created_at"] > f["until"]

      %w[e p a].all? do |name|
        vals = f[name]
        vals.empty? || ev["tags"].any? { |t| t[0] == name && vals.include?(t[1]) }
      end
    end

    def notice(conn, text)
      conn.send_text(JSON.generate(["NOTICE", text]))
    end

    def log(msg)
      return unless @logger.respond_to?(:puts)

      @logger.puts("local_relay: #{msg}")
    rescue StandardError
      nil
    end

    def pong_for(frame)
      WebSocket::Frame::Outgoing::Server.new(data: frame.data, type: :pong, version: 13).to_s
    end

    # One WebSocket client: subscription registry + serialized writes. Frame
    # decisions (ping/pong/close) live in serve; Conn only moves bytes.
    class Conn
      def initialize(sock)
        @sock = sock
        @subs = {} # sub_id => { "filters" => [...], "live" => bool }
        @wmos = Mutex.new
      end

      def set_sub(sub_id, filters)
        @subs[sub_id] = { "filters" => filters, "live" => false }
      end

      def drop_sub(sub_id) = @subs.delete(sub_id)

      def mark_live(sub_id)
        @subs[sub_id]["live"] = true if @subs[sub_id]
      end

      # dup guards against Hash-modified-during-iteration when another
      # thread CLOSEs a sub mid-broadcast.
      def each_live_sub
        @subs.dup.each { |sub_id, s| yield sub_id, s["filters"] if s["live"] }
      end

      def send_text(text)
        send_frame(WebSocket::Frame::Outgoing::Server.new(data: text, type: :text, version: 13).to_s)
      end

      def send_frame(bytes)
        @wmos.synchronize { @sock.write(bytes) }
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError, SystemCallError
        nil # write races with a dying socket; the read loop sees EOF next
      end

      def close
        @wmos.synchronize { @sock.close }
      rescue StandardError
        nil
      end
    end
  end
end
