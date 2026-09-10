# frozen_string_literal: true

require "socket"
require "json"
require "digest"
require "base64"
require "fileutils"
require "net/http"
require "uri"
require_relative "../nostr_core/event"
require_relative "../nostr_core/bip340"

module Nostrd
  module Blossom
    # Any NIP-98 auth failure; maps to 401 at the dispatch layer.
    class AuthError < StandardError; end

    # Public servers tried in order by upload_and_mirror / tooling. One
    # success per blob is enough for serving; two copies are kept.
    # NOTE: files.sovbit.host is deliberately absent — its BUD-01 PUT
    # /<sha256> route 405s and uploads there never stick; the user has
    # also blacklisted it outright.
    DEFAULT_SERVERS = %w[
      https://nostr.download
      https://cdn.nostrcheck.me
      https://blossom.primal.net
    ].freeze

    LOCAL_URL = "http://127.0.0.1:7778"

    # Client for remote Blossom servers (NIP-B7/BUD-02). Public servers carry
    # mirror to the embedded server first (restore survives an aborted run),
    # then public servers until `copies` accepted. auth is a callable
    # (url, method, body_sha) → Authorization header value; signing stays
    # with the daemon key. Returns a result hash, never raises on server
    # failures (mirrors the best-effort CLI loop).
    def self.upload_and_mirror(data:, mime:, auth:, servers: DEFAULT_SERVERS,
                               local_url: LOCAL_URL, copies: 2)
      sha = Digest::SHA256.hexdigest(data)
      local_ok = false
      if local_url
        local_ok, = Client.put(local_url, "/upload", body: data, mime: mime,
                               auth: auth.call(local_url, "PUT", sha))
      end
      urls = []
      Array(servers).each do |server|
        ok, = Client.put(server, "/upload", body: data, mime: mime,
                         auth: auth.call(server, "PUT", sha))
        urls << server if ok
        break if urls.size >= copies
      end
      { "sha" => sha, "urls" => urls, "local" => local_ok,
        "url" => (urls.first ? "#{urls.first.sub(%r{/+\z}, '')}/#{sha}" : (local_ok ? "#{local_url}/#{sha}" : nil)) }
    end

    MIME = {
      ".html" => "text/html", ".htm" => "text/html", ".js" => "text/javascript",
      ".mjs" => "text/javascript", ".css" => "text/css", ".json" => "application/json",
      ".webmanifest" => "application/manifest+json", ".png" => "image/png",
      ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
      ".svg" => "image/svg+xml", ".webp" => "image/webp", ".ico" => "image/x-icon",
      ".txt" => "text/plain", ".woff" => "font/woff", ".woff2" => "font/woff2",
      ".map" => "application/json", ".xml" => "application/xml"
    }.freeze

    def self.mime_for(path)
      MIME[File.extname(path.to_s).downcase] || "application/octet-stream"
    end

    # Embedded content-addressed blob server (NIP-B7 basics over BUD-02):
    #   PUT /upload                 NIP-98 kind-24242 auth; sha256 of the body
    #                               becomes the name; identical bytes dedupe
    #   GET|HEAD /<sha256>[.<ext>]  public read (bind 127.0.0.1); 404 JSON
    #                               when missing; the friendly extension is
    #                               tolerated but content addressing wins
    #   DELETE /<sha256>            NIP-98 auth; only the sidecar owner may
    #                               delete; removes blob + sidecar
    # Loopback-only by default — the local daemon's clients (TUI, PWA,
    # scripts) are the intended users.
    #
    # Disk layout under <dir>, sharded two-deep so no single directory holds
    # every blob:
    #   <dir>/<aa>/<remaining 62 hex>       raw blob bytes, name = sha256
    #   <dir>/<aa>/<remaining 62 hex>.meta  sidecar JSON:
    #     content_type — served as Content-Type on GET/HEAD
    #     owner        — the only pubkey allowed to DELETE
    #     created_at   — upload unix time
    # The .meta suffix keeps sidecar and blob unambiguous inside one shard.
    #
    # WEBrick left the Ruby 3.4 bundle, so HTTP/1.1 is hand-rolled on
    # TCPServer the same way LocalRelay does its upgrade path — stdlib only,
    # no Rack/Sinatra. One request per connection (Connection: close) keeps
    # the parser tiny; the accept loop and per-request rescues follow the
    # same never-die discipline as LocalRelay#serve.
    class Server
      AUTH_KIND = 24242 # NIP-98/Blossom http auth (see Signer::RAW_SIGN_KINDS)
      REQUEST_TIMEOUT = 15 # seconds for the one-request-per-connection lifetime
      STATUS_TEXT = {200 => "OK", 400 => "Bad Request", 401 => "Unauthorized",
                     403 => "Forbidden", 404 => "Not Found",
                     500 => "Internal Server Error"}.freeze

      attr_reader :host, :port, :dir

      def initialize(dir:, port: 7778, host: "127.0.0.1", logger: $stderr)
        @dir = dir
        @host = host
        @port = port
        @logger = logger
        @server = nil
        @thread = nil
        @stopping = false
        @conns = []
        @mos = Mutex.new
      end

      # Binds synchronously so callers can read #port right after (port: 0
      # resolves to the ephemeral port the test client dials), then accepts
      # in a background thread — one thread per connection, like
      # LocalRelay#start.
      def start
        @stopping = false
        @server = TCPServer.new(@host, @port)
        @port = @server.addr[1]
        @thread = Thread.new do
          Thread.current.name = "blossom" if Thread.current.respond_to?(:name=)
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
        conns.each(&:close) # closing sockets unblocks reader threads
        true
      end

      def running? = !@server.nil?

      private

      def serve(sock)
        sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) rescue nil
        # Bounded lifetime: one request per connection, so the timeout guards
        # the whole read without starving anyone.
        sock.timeout = REQUEST_TIMEOUT if sock.respond_to?(:timeout=)
        @mos.synchronize { @conns << sock }
        method, path, headers, body = read_request(sock)
        dispatch(sock, method, path, headers, body)
      rescue StandardError => e
        # Garbage bytes or a vanished client before dispatch: scoped to this
        # connection — the accept loop and every other client keep running.
        log("request error: #{e.class}: #{e.message}")
        begin
          json(sock, 400, {"error" => "bad request"})
        rescue StandardError
          nil # client is gone; nothing more to do
        end
      ensure
        @mos.synchronize { @conns.delete(sock) }
        sock.close rescue nil
      end

      # Request line + headers + Content-Length body. Anything malformed
      # raises and lands in serve's rescue as a 400.
      def read_request(sock)
        request_line = sock.gets("\r\n")
        raise ArgumentError, "empty request" if request_line.nil?

        method, path, = request_line.strip.split(" ", 3)
        raise ArgumentError, "malformed request line" if method.nil? || path.nil?

        headers = {}
        while (line = sock.gets("\r\n")) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.to_s.strip.downcase] = value.to_s.strip if key && value
        end
        body = headers["content-length"] ? sock.read(Integer(headers["content-length"])) : ""
        [method, path, headers, body.to_s]
      end

      def dispatch(sock, method, path, headers, body)
        path = path.split("?", 2).first.to_s # tolerate query strings
        head_only = method == "HEAD"
        if method == "PUT" && path == "/upload"
          ev = authorize!(headers["authorization"], "upload", body)
          store_upload(sock, headers, body, ev)
        elsif %w[GET HEAD].include?(method)
          serve_blob(sock, sha_name!(path), head_only: head_only)
        elsif method == "DELETE"
          sha = sha_name!(path)
          ev = authorize!(headers["authorization"], "delete", body)
          destroy(sock, sha, ev)
        else
          json(sock, 404, {"error" => "not found"}, head_only: head_only)
        end
      rescue AuthError => e
        json(sock, 401, {"error" => e.message}, head_only: head_only)
      rescue ArgumentError => e
        json(sock, 400, {"error" => e.message}, head_only: head_only)
      rescue StandardError => e
        # One bad request must never kill the connection thread or the loop.
        log("handler failed: #{e.class}: #{e.message}")
        json(sock, 500, {"error" => "internal error"}, head_only: head_only)
      end

      # NIP-98: "Authorization: Nostr <base64 event JSON>". The id hash and
      # BIP-340 sig go through the same relay-grade checks as
      # LocalRelay#accept_event, then the Blossom claims: kind 24242, a t-tag
      # naming the endpoint action, expiration in the future, and — when
      # present — an x-tag pinning the sha256 of the request body.
      def authorize!(header, action, body)
        raise AuthError, "missing authorization" unless header.is_a?(String)

        b64 = header.sub(/\ANostr\s+/i, "")
        raise AuthError, "not a Nostr authorization scheme" if b64 == header || b64.empty?

        ev = JSON.parse(Base64.strict_decode64(b64))
        raise AuthError, "auth event must be an object" unless ev.is_a?(Hash)

        id = ev["id"].to_s
        pubkey = ev["pubkey"].to_s
        sig = ev["sig"].to_s
        raise AuthError, "auth event is missing required fields" unless
          id.match?(/\A[0-9a-f]{64}\z/) && pubkey.match?(/\A[0-9a-f]{64}\z/) &&
          sig.match?(/\A[0-9a-f]{128}\z/) && ev["created_at"].is_a?(Integer) &&
          ev["kind"].is_a?(Integer) && ev["tags"].is_a?(Array)

        expected = Digest::SHA256.hexdigest(
          NostrCore::Event.id_payload(pubkey, ev["created_at"], ev["kind"], ev["tags"], ev["content"])
        )
        raise AuthError, "id does not match the NIP-01 serialization" unless expected == id
        raise AuthError, "signature verification failed" unless
          NostrCore::Bip340.verify([pubkey].pack("H*"), [id].pack("H*"), [sig].pack("H*"))

        raise AuthError, "kind must be #{AUTH_KIND}" unless ev["kind"] == AUTH_KIND
        t = ev["tags"].find { |tag| tag.is_a?(Array) && tag[0] == "t" }
        raise AuthError, "missing t tag" unless t
        raise AuthError, "t tag does not match the endpoint action" unless t[1] == action

        exp = ev["tags"].find { |tag| tag.is_a?(Array) && tag[0] == "expiration" }
        raise AuthError, "missing expiration" unless exp
        raise AuthError, "auth event expired" unless exp[1].to_s.to_i > Time.now.to_i

        x = ev["tags"].find { |tag| tag.is_a?(Array) && tag[0] == "x" }
        raise AuthError, "x tag does not match the body sha256" if
          x && x[1].to_s.downcase != Digest::SHA256.hexdigest(body)

        ev
      rescue ArgumentError, JSON::ParserError
        raise AuthError, "authorization is not base64 event JSON"
      end

      def store_upload(sock, headers, body, ev)
        sha = Digest::SHA256.hexdigest(body)
        blob = blob_path(sha)
        unless File.exist?(blob)
          # Content addressing does the dedupe: identical bytes collapse to
          # one file and the first uploader's sidecar (ownership) stays.
          FileUtils.mkdir_p(File.dirname(blob))
          tmp = "#{blob}.#{$$}.tmp"
          File.binwrite(tmp, body)
          File.rename(tmp, blob) # atomic publish; never a torn blob
          content_type = headers["content-type"].to_s.strip
          File.write(meta_path(sha), JSON.generate(
            "content_type" => content_type.empty? ? "application/octet-stream" : content_type,
            "owner" => ev["pubkey"],
            "created_at" => Time.now.to_i
          ))
        end
        json(sock, 200, {"status" => "success", "url" => "http://#{@host}:#{@port}/#{sha}",
                         "sha256" => sha, "size" => body.bytesize})
      end

      def serve_blob(sock, sha, head_only: false)
        blob = blob_path(sha)
        return json(sock, 404, {"error" => "not found"}, head_only: head_only) unless File.file?(blob)

        meta = read_meta(sha)
        respond(sock, 200, File.binread(blob),
                content_type: meta["content_type"] || "application/octet-stream",
                head_only: head_only)
      end

      def destroy(sock, sha, ev)
        blob = blob_path(sha)
        return json(sock, 404, {"error" => "not found"}) unless File.exist?(blob)

        return json(sock, 403, {"error" => "forbidden: not the blob owner"}) unless
          read_meta(sha)["owner"] == ev["pubkey"]

        File.delete(blob)
        File.delete(meta_path(sha)) if File.exist?(meta_path(sha))
        json(sock, 200, {"status" => "deleted", "sha256" => sha})
      end

      # Missing/corrupt sidecar degrades to defaults instead of failing reads.
      def read_meta(sha)
        File.exist?(meta_path(sha)) ? JSON.parse(File.read(meta_path(sha))) : {}
      rescue JSON::ParserError
        {}
      end

      # /<64 hex> or /<64 hex>.<ext>; hex-only validation doubles as the
      # path-traversal gate — nothing outside @dir is reachable by name.
      def sha_name!(path)
        name = path.delete_prefix("/").split(".", 2).first.to_s
        raise ArgumentError, "invalid blob path" unless name.match?(/\A[0-9a-f]{64}\z/)

        name
      end

      def json(sock, status, obj, head_only: false)
        respond(sock, status, JSON.generate(obj), head_only: head_only)
      end

      def respond(sock, status, body, content_type: "application/json", head_only: false)
        sock.write(
          "HTTP/1.1 #{status} #{STATUS_TEXT.fetch(status)}\r\n" \
          "Content-Type: #{content_type}\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n\r\n"
        )
        sock.write(body) unless head_only
      end

      def blob_path(sha)
        File.join(@dir, sha[0, 2], sha[2, 62])
      end

      def meta_path(sha)
        "#{blob_path(sha)}.meta"
      end

      def log(msg)
        @logger.puts("[blossom] #{msg}")
      rescue StandardError
        nil # a dead logger must not kill the accept loop
      end
    end

    # Client for remote Blossom servers (NIP-B7/BUD-02). Public servers carry
    # the serving load; the embedded one is the private mirror of last
    # resort. Signing stays with the daemon: callers pass the finished
    # NIP-98 Authorization header.
    module Client
      module_function

      # PUT a blob. Returns [ok, info] (info is a short human string).
      def put(server, path, body:, mime:, auth:, timeout: 30)
        uri = URI.parse("#{server.to_s.chomp('/')}/#{path.delete_prefix('/')}")
        req = Net::HTTP::Put.new(uri)
        req.body = body
        req["Authorization"] = auth
        req["Content-Type"] = mime
        res = http(uri, timeout) { |h| h.request(req) }
        [res.code.to_i.between?(200, 299),
         "#{res.code} #{res.body.to_s[0, 60].gsub(/\s+/, ' ')}"]
      rescue StandardError => e
        [false, "ERR #{e.class}"]
      end

      # GET across candidate servers in order; first 2xx wins. Returns
      # [body, content_type] or nil when every source misses — the public
      # first / local mirror last fallback rides on this.
      def get(urls, path, timeout: 15)
        urls.compact.each do |url|
          uri = URI.parse("#{url.to_s.chomp('/')}/#{path.delete_prefix('/')}")
          res = http(uri, timeout) { |h| h.request(Net::HTTP::Get.new(uri)) }
          next unless res.code.to_i.between?(200, 299)

          return [res.body.to_s, res["Content-Type"]]
        rescue StandardError
          next # dead server, timeout, TLS error: just try the next source
        end
        nil
      end

      def http(uri, timeout)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 8
        http.read_timeout = timeout
        http.start { |h| yield h }
      end

      # Loopback hosts must never enter published server tags/manifests —
      # a private mirror URL is meaningless (and noisy) to the outside.
      def loopback?(url)
        host = URI.parse(url.to_s).host.to_s.downcase
        host == "localhost" || host == "[::1]" || host.start_with?("127.", "::1")
      rescue URI::Error
        true # unparseable URLs are treated private, not published
      end
    end
  end
end
