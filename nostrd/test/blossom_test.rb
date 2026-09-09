# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "net/http"
require "base64"
require "digest"
require "securerandom"
require "socket"
require_relative "../lib/nostrd/blossom"
require_relative "../lib/nostr_core/bip340"

# Real-HTTP coverage for the embedded Blossom blob server: throwaway keypairs
# mint NIP-98 kind-24242 auth events (Bip340-direct, no vault — same trick as
# raw_sign_test.rb) and everything rides Net::HTTP against an ephemeral port.
class BlossomTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @sk, @pk = new_identity
    @other_sk, @other_pk = new_identity
    @server = Nostrd::Blossom::Server.new(dir: @dir, port: 0, logger: IO::NULL)
    @server.start
  end

  def teardown
    @server.stop
    FileUtils.remove_entry(@dir)
  end

  def test_upload_get_head_roundtrip
    blob = SecureRandom.bytes(1024)
    sha = Digest::SHA256.hexdigest(blob)
    res = upload(blob, @sk, @pk, content_type: "application/x-birdsong")

    assert_equal 200, res.code.to_i
    data = JSON.parse(res.body)
    assert_equal "success", data["status"]
    assert_equal sha, data["sha256"]
    assert_equal 1024, data["size"]
    assert_equal "http://#{@server.host}:#{@server.port}/#{sha}", data["url"]

    # Disk layout: <dir>/<2 hex>/<62 hex> plus the .meta sidecar.
    assert File.file?(blob_file(sha))
    meta = JSON.parse(File.read(meta_file(sha)))
    assert_equal "application/x-birdsong", meta["content_type"]
    assert_equal @pk, meta["owner"]
    assert_kind_of Integer, meta["created_at"]

    got = request(:get, "/#{sha}")
    assert_equal 200, got.code.to_i
    assert_equal blob, got.body # identical bytes back
    assert_equal "application/x-birdsong", got["Content-Type"]

    # BUD-02 tolerates a friendly extension; content addressing still wins.
    assert_equal blob, request(:get, "/#{sha}.bin").body

    head = request(:head, "/#{sha}")
    assert_equal 200, head.code.to_i
    assert_equal "application/x-birdsong", head["Content-Type"]
    assert_empty head.body.to_s
  end

  def test_reupload_dedupes_to_one_blob
    blob = SecureRandom.bytes(64)
    sha = Digest::SHA256.hexdigest(blob)
    first = upload(blob, @sk, @pk)
    second = upload(blob, @other_sk, @other_pk)

    assert_equal 200, first.code.to_i
    assert_equal 200, second.code.to_i
    assert_equal JSON.parse(first.body)["sha256"], JSON.parse(second.body)["sha256"]
    assert_equal sha, JSON.parse(second.body)["sha256"]

    # Exactly one blob + one sidecar survive, and ownership stays with the
    # first uploader even after the duplicate.
    files = Dir.glob(File.join(@dir, "**", "*")).select { |f| File.file?(f) }
    assert_equal 2, files.size
    assert_equal @pk, JSON.parse(File.read(meta_file(sha)))["owner"]
  end

  def test_upload_requires_valid_auth
    blob = SecureRandom.bytes(32)
    sha = Digest::SHA256.hexdigest(blob)

    # missing header
    assert_equal 401, request(:put, "/upload", body: blob).code.to_i

    # tampered signature (valid shape, fails BIP-340 verify)
    assert_equal 401, request(:put, "/upload",
                              headers: tamper_event(upload_auth(blob), "sig", "f" * 128),
                              body: blob).code.to_i

    # expired auth event
    expired = upload_auth(blob, expires_in: -10)
    res = request(:put, "/upload", headers: expired, body: blob)
    assert_equal 401, res.code.to_i
    assert_equal "application/json", res["Content-Type"]
    assert_includes JSON.parse(res.body), "error"

    # signed for the wrong endpoint action
    assert_equal 401, request(:put, "/upload",
                              headers: auth_header(action: "delete", sk: @sk, pk: @pk, body: blob),
                              body: blob).code.to_i

    # x tag does not match sha256 of the body
    assert_equal 401, request(:put, "/upload",
                              headers: upload_auth(blob, x: "ab" * 32),
                              body: blob).code.to_i

    # tampered id (id no longer matches the NIP-01 serialization)
    assert_equal 401, request(:put, "/upload",
                              headers: tamper_event(upload_auth(blob), "id", "ab" * 64),
                              body: blob).code.to_i

    # garbage in the Nostr scheme (not base64 event JSON at all)
    assert_equal 401, request(:put, "/upload",
                              headers: {"authorization" => "Nostr ???not base64???"},
                              body: blob).code.to_i

    # none of the rejected attempts stored anything
    refute File.exist?(blob_file(sha))
  end

  def test_delete_rejects_non_owner_then_owner_succeeds
    blob = SecureRandom.bytes(128)
    sha = Digest::SHA256.hexdigest(blob)
    upload(blob, @sk, @pk)

    res = request(:delete, "/#{sha}",
                  headers: auth_header(action: "delete", sk: @other_sk, pk: @other_pk))
    assert_equal 403, res.code.to_i
    assert_equal 200, request(:get, "/#{sha}").code.to_i # untouched

    ok = request(:delete, "/#{sha}",
                 headers: auth_header(action: "delete", sk: @sk, pk: @pk))
    assert_equal 200, ok.code.to_i
    assert_equal 404, request(:get, "/#{sha}").code.to_i
    refute File.exist?(blob_file(sha))
    refute File.exist?(meta_file(sha))
  end

  def test_delete_and_get_missing_blob_are_404
    missing = "/" + ("cd" * 32)
    assert_equal 404, request(:delete, missing,
                              headers: auth_header(action: "delete", sk: @sk, pk: @pk)).code.to_i
    res = request(:get, missing)
    assert_equal 404, res.code.to_i
    assert_equal "application/json", res["Content-Type"]
    assert_includes JSON.parse(res.body), "error"
  end

  def test_get_falls_back_to_octet_stream_without_sidecar
    blob = SecureRandom.bytes(8)
    sha = Digest::SHA256.hexdigest(blob)
    assert_equal 200, upload(blob, @sk, @pk).code.to_i
    File.delete(meta_file(sha))

    res = request(:get, "/#{sha}")
    assert_equal 200, res.code.to_i
    assert_equal "application/octet-stream", res["Content-Type"]
    assert_equal blob, res.body
  end

  def test_server_survives_garbage_input
    # Raw garbage on the socket: the per-connection rescue answers 400 and
    # the accept loop keeps serving real traffic afterwards.
    TCPSocket.open(@server.host, @server.port) do |sock|
      sock.write("GARBAGE\r\n\r\n")
      ready = IO.select([sock], nil, nil, 5)
      assert ready, "server should answer garbage with a response"
      assert_match(/\AHTTP\/1\.1 400 /, sock.read(64) || "")
    end
    assert @server.running?
    assert_equal 200, upload(SecureRandom.bytes(16), @sk, @pk).code.to_i
  end

  private

  def new_identity
    sk = SecureRandom.random_bytes(32)
    [sk, NostrCore::Bip340.public_key(sk)]
  end

  def upload_auth(body, expires_in: 60, x: :derive)
    auth_header(action: "upload", sk: @sk, pk: @pk, body: body,
                expires_in: expires_in, x: x)
  end

  # Signs a kind-24242 NIP-98 auth event with a throwaway key and wraps it
  # in the "Authorization: Nostr <base64>" header BUD-02 expects. x: :derive
  # pins the body sha256; a String pins that literal (for mismatch tests).
  def auth_header(action:, sk:, pk:, body: nil, expires_in: 60, x: :derive)
    tags = [["t", action], ["expiration", (Time.now.to_i + expires_in).to_s]]
    if x == :derive
      tags << ["x", Digest::SHA256.hexdigest(body)] if body
    elsif x
      tags << ["x", x]
    end
    created_at = Time.now.to_i
    payload = NostrCore::Event.id_payload(pk, created_at, 24242, tags, "")
    id = Digest::SHA256.hexdigest(payload)
    sig = NostrCore::Bip340.sign([id].pack("H*"), sk, SecureRandom.random_bytes(32))
    ev = {"id" => id, "pubkey" => pk, "created_at" => created_at, "kind" => 24242,
          "tags" => tags, "content" => "", "sig" => sig.unpack1("H*")}
    {"authorization" => "Nostr #{Base64.strict_encode64(JSON.generate(ev))}"}
  end

  def tamper_event(headers, field, value)
    ev = JSON.parse(Base64.strict_decode64(headers["authorization"].sub(/\ANostr /, "")))
    ev[field] = value
    {"authorization" => "Nostr #{Base64.strict_encode64(JSON.generate(ev))}"}
  end

  def upload(blob, sk, pk, content_type: nil)
    headers = auth_header(action: "upload", sk: sk, pk: pk, body: blob)
    headers["content-type"] = content_type if content_type
    request(:put, "/upload", headers: headers, body: blob)
  end

  def request(method, path, headers: {}, body: nil)
    http = Net::HTTP.new(@server.host, @server.port)
    http.read_timeout = 10
    req =
      case method
      when :put then Net::HTTP::Put.new(path, headers)
      when :get then Net::HTTP::Get.new(path, headers)
      when :head then Net::HTTP::Head.new(path, headers)
      when :delete then Net::HTTP::Delete.new(path, headers)
      end
    req.body = body if body
    http.request(req)
  end

  def blob_file(sha)
    File.join(@dir, sha[0, 2], sha[2, 62])
  end

  def meta_file(sha)
    "#{blob_file(sha)}.meta"
  end
end
