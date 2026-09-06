# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../lib/nostrd/bunker"
require_relative "../lib/nostr_core/bip340"
require_relative "../lib/nostr_core/event"

# Bunker: config persistence, URI format, and a full in-process crypto loop
# (client encrypts a request, bunker handles it, client decrypts the
# response) — no real relay needed.
class BunkerTest < Minitest::Test
  CLIENT = "c" * 64

  class FakeSigner
    attr_reader :pubkey, :seckey

    def initialize
      @seckey = SecureRandom.random_bytes(32)
      @pubkey = NostrCore::Bip340.public_key(@seckey)
    end

    def locked? = false

    def sign_event(kind, content, tags = [], created_at: Time.now.to_i)
      event = { pubkey: @pubkey, created_at: created_at, kind: kind, tags: tags, content: content }
      payload = JSON.generate([0, @pubkey, created_at, kind, tags, content])
      id = Digest::SHA256.hexdigest(payload)
      sig = NostrCore::Bip340.sign([id].pack("H*"), @seckey, SecureRandom.random_bytes(32))
      event.merge(id: id, sig: sig.unpack1("H*"))
    end
  end

  class FakePool
    attr_reader :published

    def initialize = (@published = [])

    def publish(event, urls: nil)
      @published << [event, urls]
      [urls].flatten.compact
    end
  end

  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "bunker.json")
    @signer = FakeSigner.new
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  def config(secret: nil)
    cfg = Nostrd::Bunker::Config.new(path: @path)
    cfg.instance_variable_get(:@data)["secret"] = secret if secret
    cfg
  end

  def test_config_roundtrip_and_permissions
    cfg = config(secret: "ab" * 16)
    cfg.allow!(CLIENT)
    cfg.relays = ["wss://r.example", "not-a-url"]
    assert File.exist?(@path)
    assert_equal 0600, File.stat(@path).mode & 0777

    again = Nostrd::Bunker::Config.new(path: @path)
    assert_equal "ab" * 16, again.secret
    assert_equal [CLIENT], again.clients
    assert_equal ["wss://r.example"], again.relays # non-ws dropped
  end

  def test_bunker_uri_joins_relays_with_ampersands
    cfg = config(secret: "ab" * 16)
    cfg.relays = ["wss://r1.example", "wss://r2.example/ws"]
    uri = cfg.bunker_uri(@signer.pubkey)
    assert_equal "bunker://#{@signer.pubkey}?relay=wss%3A%2F%2Fr1.example&relay=wss%3A%2F%2Fr2.example%2Fws&secret=#{'ab' * 16}", uri
  end

  def test_ensure_secret_is_stable
    cfg = config
    s1 = cfg.ensure_secret!
    assert_match(/\A[0-9a-f]{32}\z/, s1)
    assert_equal s1, config.ensure_secret! # reloaded from disk, not rotated
  end

  # Full round trip: client keypair encrypts `connect`, the bunker handles
  # the kind-24133 event, the client decrypts "ack", then a signed event
  # comes back through sign_event and verifies.
  def test_connect_and_sign_loop
    cfg = config(secret: "ab" * 16)
    pool = FakePool.new
    bunker = Nostrd::Bunker.new(signer: @signer, config: cfg, pool: pool)
    assert bunker.enabled?

    client_sk = SecureRandom.random_bytes(32)
    client_pk = NostrCore::Bip340.public_key(client_sk)

    request_event = kind_24133(client_sk, client_pk, @signer.pubkey,
                               { "id" => "q1", "method" => "connect",
                                 "params" => [@signer.pubkey, "ab" * 16] })
    bunker.handle_event(request_event, url: "ws://source-relay")
    assert_includes cfg.clients, client_pk # allowlisted

    resp = decrypt_last_response(pool, client_sk)
    assert_equal "q1", resp["id"]
    assert_equal "ack", resp["result"]
    assert bunker.active?(client_pk)

    # sign_event round trip
    request_event = kind_24133(client_sk, client_pk, @signer.pubkey,
                               { "id" => "q2", "method" => "sign_event",
                                 "params" => [{ "kind" => 1, "content" => "hello", "tags" => [] }] })
    bunker.handle_event(request_event, url: "ws://source-relay")
    resp = decrypt_last_response(pool, client_sk)
    assert_equal "q2", resp["id"]
    ev = JSON.parse(resp["result"])
    payload = JSON.generate([0, ev["pubkey"], ev["created_at"], ev["kind"], ev["tags"], ev["content"]])
    assert_equal ev["id"], Digest::SHA256.hexdigest(payload)
    assert NostrCore::Bip340.verify([ev["pubkey"]].pack("H*"), [ev["id"]].pack("H*"),
                                    [ev["sig"]].pack("H*"))
  end

  def test_response_goes_to_source_relay
    cfg = config(secret: "ab" * 16)
    pool = FakePool.new
    bunker = Nostrd::Bunker.new(signer: @signer, config: cfg, pool: pool)
    client_sk = SecureRandom.random_bytes(32)
    client_pk = NostrCore::Bip340.public_key(client_sk)

    bunker.handle_event(kind_24133(client_sk, client_pk, @signer.pubkey,
                                   { "id" => "q1", "method" => "connect",
                                     "params" => [@signer.pubkey, "ab" * 16] }),
                        url: "ws://source-relay")
    first, urls = pool.published.first
    assert_equal "ws://source-relay", urls.first
    assert_equal 24133, first[:kind]
    assert_equal [["p", client_pk]], first[:tags]
  end

  def test_garbage_request_is_dropped_not_raised
    bunker = Nostrd::Bunker.new(signer: @signer, config: config(secret: "ab" * 16))
    garbage = { "kind" => 24133, "pubkey" => CLIENT,
                "tags" => [["p", @signer.pubkey]], "content" => "not-base64!!" }
    bunker.handle_event(garbage, url: "ws://x") # must not raise
    assert_empty bunker.session_pubkeys
  end

  def test_disabled_bunker_ignores_everything
    bunker = Nostrd::Bunker.new(signer: @signer, config: config(secret: nil))
    refute bunker.enabled?
    bunker.handle_event({ "kind" => 24133, "pubkey" => CLIENT,
                          "tags" => [["p", @signer.pubkey]], "content" => "x" }, url: "ws://x")
    assert_empty bunker.session_pubkeys
  end

  private

  def kind_24133(client_sk, client_pk, signer_pk, request)
    content = NostrCore::Nip44.encrypt(client_sk, [signer_pk].pack("H*"), JSON.generate(request))
    created_at = Time.now.to_i
    event = { "pubkey" => client_pk, "created_at" => created_at, "kind" => 24133,
              "tags" => [["p", signer_pk]], "content" => content }
    payload = JSON.generate([0, client_pk, created_at, 24133, event["tags"], content])
    id = Digest::SHA256.hexdigest(payload)
    sig = NostrCore::Bip340.sign([id].pack("H*"), client_sk, SecureRandom.random_bytes(32))
    event.merge("id" => id, "sig" => sig.unpack1("H*"))
  end

  def decrypt_last_response(pool, client_sk)
    event, = pool.published.last
    JSON.parse(NostrCore::Nip44.decrypt(client_sk, [@signer.pubkey].pack("H*"), event[:content]))
  end
end
