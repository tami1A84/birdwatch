# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/nostrd/nip46"

# NIP-46 handler semantics: secret/allowlist connect, session gating,
# sign_event result shape. FakeSigner/FakeConfig stand in for the daemon.
class Nip46HandlerTest < Minitest::Test
  CLIENT = "c" * 64
  OTHER = "d" * 64
  SECRET = "feedface" * 4

  class FakeSigner
    attr_reader :pubkey

    def initialize
      @pubkey = "a" * 64
      @locked = false
    end

    def locked? = @locked
    def lock = (@locked = true)

    def sign_event(kind, content, tags = [], created_at: Time.now.to_i)
      { pubkey: @pubkey, created_at: created_at, kind: kind, tags: tags,
        content: content, id: "e" * 64, sig: "s" * 128 }
    end
  end

  class FakeConfig
    attr_accessor :secret

    def initialize(secret: SECRET)
      @secret = secret
      @clients = []
    end

    def allow?(pk) = @clients.include?(pk)

    def allow!(pk)
      @clients << pk unless @clients.include?(pk)
      pk
    end

    def clients = @clients
  end

  def setup
    @signer = FakeSigner.new
    @config = FakeConfig.new
    @handler = Nostrd::Nip46Handler.new(signer: @signer, config: @config)
  end

  def connect(handler = @handler, client: CLIENT, secret: SECRET)
    handler.handle({ "id" => "r1", "method" => "connect",
                     "params" => [@signer.pubkey, secret] }, client_pubkey: client)
  end

  def test_connect_with_wrong_secret_is_rejected
    resp = connect(secret: "wrong")
    assert_equal "r1", resp["id"]
    assert_equal -32001, resp.dig("error", "code")
    assert_match(/not authorized/, resp.dig("error", "message"))
    refute @handler.active?(CLIENT)
    assert_empty @config.clients
  end

  def test_connect_with_secret_allowlists_and_registers_session
    resp = connect
    assert_equal "ack", resp["result"]
    assert @handler.active?(CLIENT)
    assert_includes @config.clients, CLIENT
  end

  def test_connect_checks_remote_signer_pubkey
    resp = @handler.handle({ "id" => "r1", "method" => "connect",
                             "params" => [("b" * 64), SECRET] }, client_pubkey: CLIENT)
    assert_equal -32001, resp.dig("error", "code")
  end

  def test_allowlisted_client_reconnects_without_secret
    @config.instance_variable_get(:@clients) << CLIENT
    resp = connect(secret: "")
    assert_equal "ack", resp["result"]
  end

  def test_unknown_client_gets_nothing_without_connect
    resp = @handler.handle({ "id" => "r2", "method" => "get_public_key", "params" => [] },
                           client_pubkey: OTHER)
    assert_equal -32001, resp.dig("error", "code")
  end

  def test_sign_event_returns_json_string_and_honors_created_at
    connect
    resp = @handler.handle(
      { "id" => "r3", "method" => "sign_event",
        "params" => [{ "kind" => 1, "content" => "hi", "tags" => [["t", "x"]], "created_at" => 1_700 }] },
      client_pubkey: CLIENT
    )
    ev = JSON.parse(resp["result"])
    assert_equal 1, ev["kind"]
    assert_equal "hi", ev["content"]
    assert_equal 1_700, ev["created_at"]
    assert_equal @signer.pubkey, ev["pubkey"]
  end

  def test_sign_event_accepts_json_string_params
    connect
    resp = @handler.handle(
      { "id" => "r4", "method" => "sign_event",
        "params" => [JSON.generate({ "kind" => 1, "content" => "str", "tags" => [] })] },
      client_pubkey: CLIENT
    )
    assert_equal "str", JSON.parse(resp["result"])["content"]
  end

  def test_disconnect_clears_session_only
    connect
    resp = @handler.handle({ "id" => "r5", "method" => "disconnect", "params" => [] },
                           client_pubkey: CLIENT)
    assert_equal "ack", resp["result"]
    refute @handler.active?(CLIENT)
    # allowlist persists: reconnect without secret works
    assert_equal "ack", connect(secret: "")["result"]
  end

  def test_unknown_method_is_an_error
    connect
    resp = @handler.handle({ "id" => "r6", "method" => "nip04_decrypt", "params" => [] },
                           client_pubkey: CLIENT)
    assert_equal -32601, resp.dig("error", "code")
  end

  def test_locked_signer_refuses_signing_but_not_connect
    connect
    @signer.lock
    resp = @handler.handle({ "id" => "r7", "method" => "sign_event",
                             "params" => [{ "kind" => 1, "content" => "x", "tags" => [] }] },
                           client_pubkey: CLIENT)
    assert_match(/locked/, resp.dig("error", "message"))
  end
end
