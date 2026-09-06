# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"
require "cgi"
require "securerandom"
require "json"
require "digest"
require "websocket"
require_relative "nostr_core/bip340"
require_relative "nostr_core/nip44"

# NIP-46 client: the web app talks to the nostrd bunker over the kind-24133
# relay transport (NIP-44 encrypted JSON-RPC). The app holds only an
# ephemeral client keypair (persisted in an encrypted cookie) — signing
# power stays with the home daemon, which authorizes clients via its
# secret/allowlist (bin/nostr --bunker-secret).
#
# Transport per NIP-46: we publish a kind-24133 request event to every relay
# listed in the bunker URI and listen for the matching response on all of
# them (the bunker answers on the relay it received the request on, which we
# cannot know in advance). One blocking call() = one fresh connection set;
# the web does a handful of writes per request at most, so dial cost is fine.
class Nip46Client
  class Error      < StandardError; end
  class Timeout    < Error; end
  class Rejected   < Error; end # bunker answered with an error
  class Malformed  < Error; end # bad URI / bad response

  HANDSHAKE_TIMEOUT = 6
  REQUEST_TIMEOUT   = 15

  attr_reader :signer_pubkey, :secret, :relays, :pubkey

  # bunker://<signer-pubkey-hex>?relay=<url>&relay=<url>&secret=<secret>
  def self.parse_bunker_uri(uri)
    u = URI.parse(uri.to_s.strip)
    raise Malformed, "bunker:// URIではありません" unless u.scheme == "bunker"

    signer = u.host || u.opaque.to_s
    raise Malformed, "署名者の公開鍵が不正です" unless signer.match?(/\A[0-9a-f]{64}\z/)

    q = u.query ? CGI.parse(u.query) : {}
    relays = Array(q["relay"]).flatten.map(&:to_s).reject(&:empty?)
    relays.each do |r|
      raise Malformed, "relayが不正です: #{r}" unless r.match?(/\Aws{1,2}:\/\//)
    end
    raise Malformed, "relayが指定されていません" if relays.empty?

    secret = q["secret"].to_a.first.to_s
    new(signer_pubkey: signer, relays: relays, secret: secret)
  end

  def initialize(signer_pubkey:, relays:, secret:, seckey_hex: nil, timeout: REQUEST_TIMEOUT)
    @signer_pubkey = signer_pubkey
    @relays = relays
    @secret = secret.to_s
    @timeout = timeout
    @seckey = seckey_hex ? [seckey_hex].pack("H*") : Nip46Client.fresh_seckey
    @pubkey = NostrCore::Bip340.public_key(@seckey)
  end

  def self.fresh_seckey
    loop do
      sk = SecureRandom.random_bytes(32)
      return sk if NostrCore::Bip340.public_key(sk).match?(/\A[0-9a-f]{64}\z/)
    end
  end

  def client_pubkey  = @pubkey # Bip340.public_key returns hex
  def seckey_hex     = @seckey.unpack1("H*")
  def signer_npub_short = @signer_pubkey[0, 8]

  # NIP-46 connect: params [<remote-signer-pubkey>, <secret>]. Result is
  # "ack" (or the echoed secret). Once our client pubkey is on the daemon's
  # allowlist, the daemon also accepts a secret-less reconnect.
  def connect!
    result = call("connect", [@signer_pubkey, @secret].reject(&:empty?))
    return true if result == "ack" || (@secret.present? && result == @secret)

    raise Rejected, "bunkerが接続を承認しませんでした: #{result}"
  end

  def get_public_key = call("get_public_key", [])
  def disconnect!    = call("disconnect", [])

  # Returns the signed event as a hash (NIP-46 result is a JSON string).
  def sign_event(kind:, content:, tags: [], created_at: nil)
    ev = { kind: kind, content: content, tags: tags, created_at: created_at || Time.now.to_i }
    raw = call("sign_event", [ev])
    raw.is_a?(String) ? JSON.parse(raw) : raw
  end

  # -- core round trip -------------------------------------------------------

  def call(method, params = [])
    id = SecureRandom.hex(8)
    request = { id: id, method: method, params: params }
    event = encrypt_request(request)
    response = round_trip(event, id)
    raise Rejected, response["error"].to_s if response["error"]

    response["result"]
  end

  private

  def encrypt_request(request)
    created_at = Time.now.to_i
    content = NostrCore::Nip44.encrypt(@seckey, [signer_pubkey].pack("H*"), JSON.generate(request))
    unsigned = { pubkey: client_pubkey, created_at: created_at, kind: 24133,
                 tags: [["p", signer_pubkey]], content: content }
    payload = JSON.generate([0, unsigned[:pubkey], created_at, unsigned[:kind],
                             unsigned[:tags], unsigned[:content]])
    id = Digest::SHA256.hexdigest(payload)
    sig = NostrCore::Bip340.sign([id].pack("H*"), @seckey, SecureRandom.random_bytes(32))
    unsigned.merge(id: id, sig: sig.unpack1("H*"))
  end

  # Publish the request to every URI relay, listen on all of them, and return
  # the first decryptable response matching our request id. Dials run in
  # parallel — a dead public relay must not delay the working one. Stale or
  # foreign 24133 traffic (relays replay stored events) is skipped: only a
  # response whose id matches this request ends the wait.
  def round_trip(request_event, request_id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
    inbox = Queue.new
    dial_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
    dial_threads = @relays.map do |url|
      Thread.new { open_relay(url, request_event, inbox) }
    end
    dial_threads.each do |t|
      t.report_on_exception = false
      t.abort_on_exception = false
    end
    dial_threads.each do |t|
      remaining = dial_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      t.join(remaining.positive? ? remaining : 0)
    end
    sessions = dial_threads.filter_map(&:value).compact
    raise Error, "リレーに接続できませんでした (#{@relays.join(', ')})" if sessions.empty?

    begin
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout, "bunkerの応答がタイムアウトしました" if remaining <= 0

        frame = inbox.pop(timeout: remaining)
        next unless frame

        response = extract_response(frame)
        next unless response
        next unless response["id"] == request_id # stale replay — keep waiting

        return response
      end
    ensure
      sessions.each do |s|
        s.reader&.kill
        begin
          s.sock.close
        rescue StandardError
          nil
        end
      end
    end
  end

  def extract_response(frame)
    msg = JSON.parse(frame)
    return nil unless msg.is_a?(Array) && msg[0] == "EVENT"

    ev = msg[2]
    return nil unless ev.is_a?(Hash) && ev["kind"] == 24133
    return nil unless ev["pubkey"] == signer_pubkey
    return nil unless ev["tags"].to_a.any? { |t| t.is_a?(Array) && t[0] == "p" && t[1] == client_pubkey }

    plaintext = NostrCore::Nip44.decrypt(@seckey, [signer_pubkey].pack("H*"), ev["content"])
    JSON.parse(plaintext)
  rescue StandardError
    nil # not for us / garbage / our NIP-44 raising — keep listening
  end

  # One blocking relay connection: handshake, REQ for responses, EVENT for
  # the request. Frames are pushed to the shared inbox.
  RelaySession = Struct.new(:url, :sock, :frames, :sub_id, :reader)

  def open_relay(url, request_event, inbox)
    uri = URI.parse(url)
    tcp = Socket.tcp(uri.host, uri.port || (uri.scheme == "wss" ? 443 : 80),
                     connect_timeout: HANDSHAKE_TIMEOUT)
    tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    tcp.timeout = HANDSHAKE_TIMEOUT
    sock = uri.scheme == "wss" ? tls_wrap(uri, tcp) : tcp

    key = SecureRandom.base64(16)
    path = uri.path.empty? ? "/" : uri.path
    sock.write(
      "GET #{path} HTTP/1.1\r\nHost: #{uri.host}\r\nUpgrade: websocket\r\n" \
      "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
    handshake = +""
    while !handshake.include?("\r\n\r\n") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      handshake << sock.readpartial(4096)
    end
    raise Malformed, "websocket handshake failed: #{url}" unless handshake.include?(" 101")

    session = RelaySession.new(url, sock, WebSocket::Frame::Incoming::Client.new, "nip46-#{SecureRandom.hex(4)}")
    sub = NostrCoreRelayReq.for_client(client_pubkey, signer_pubkey, session.sub_id)
    sock.write(ws_text(JSON.generate(["REQ", session.sub_id, sub])))
    sock.write(ws_text(JSON.generate(["EVENT", request_event])))

    reader = Thread.new do
      loop do
        data = sock.readpartial(16_384)
        session.frames << data
        while (frame = session.frames.next)
          case frame.type
          when :ping then sock.write(pong_for(frame))
          when :close then raise EOFError
          when :text then inbox << frame.data.to_s
          end
        end
      end
    end
    reader.report_on_exception = false
    reader.abort_on_exception = false
    session.reader = reader
    session
  rescue StandardError
    sock.close rescue nil
    nil
  end

  def tls_wrap(uri, tcp)
    ssl = OpenSSL::SSL::SSLSocket.new(tcp)
    ssl.sync_close = true
    ssl.hostname = uri.host
    ssl.connect
    ssl
  end

  def ws_text(data)
    WebSocket::Frame::Outgoing::Client.new(data: data, type: :text, version: 13).to_s
  end

  def pong_for(frame)
    WebSocket::Frame::Outgoing::Client.new(data: frame.data, type: :pong, version: 13).to_s
  end
end

# REQ filter helper kept outside Nip46Client for readability: responses are
# kind-24133 events authored by the signer, p-tagged to the client.
module NostrCoreRelayReq
  module_function

  def for_client(client_pubkey, signer_pubkey, sub_id)
    { kinds: [24133], "#p": [client_pubkey], authors: [signer_pubkey], since: Time.now.to_i - 10 }
  end
end
