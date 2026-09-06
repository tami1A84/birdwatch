# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/nostrd/server"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostrd/bunker"
require_relative "../lib/nostr_core/bip340"

# The bunker-aware parts of the socket API: the info op bunker block and the
# action client gate. Dispatched against a FakeConn (web_ops_test style).
class BunkerOpsTest < Minitest::Test
  CLIENT = "c" * 64

  class StubBunker
    attr_reader :sessions

    def initialize(enabled:, sessions: [])
      @enabled = enabled
      @sessions = sessions
    end

    def enabled? = @enabled
    def session_pubkeys = @sessions
    def active?(pk) = @sessions.include?(pk)
  end

  class StubSigner
    attr_reader :pubkey

    def initialize = (@pubkey = "a" * 64)
    def locked? = false

    def call(name, params)
      { id: "signed-#{name}" }
    end
  end

  FakeConn = Struct.new(:out) do
    def initialize = (self.out = [])
    def puts(line) = (out << line)
    def close = nil
  end

  def mk_server(bunker)
    Nostrd::Server.new(store: Nostrd::Store.new(":memory:"), socket_path: "/tmp/x.sock",
                       signer: StubSigner.new, bunker: bunker,
                       info: -> { { "me" => "a" * 64 } })
  end

  def msgs(conn) = conn.out.map { |l| JSON.parse(l) }

  def test_info_carries_bunker_block
    srv = mk_server(StubBunker.new(enabled: true, sessions: [CLIENT]))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "info", "id" => "i1" })
    info = msgs(conn).last
    assert_equal true, info.dig("bunker", "enabled")
    assert_equal [CLIENT], info.dig("bunker", "sessions")
  end

  def test_action_with_active_client_session_passes
    srv = mk_server(StubBunker.new(enabled: true, sessions: [CLIENT]))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "action", "id" => "a1", "name" => "post_note",
                                "params" => { "text" => "hi" }, "client" => CLIENT })
    ack = msgs(conn).last
    assert_equal true, ack["ok"]
  end

  def test_action_with_unknown_client_is_rejected
    srv = mk_server(StubBunker.new(enabled: true, sessions: []))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "action", "id" => "a2", "name" => "post_note",
                                "params" => { "text" => "hi" }, "client" => "d" * 64 })
    ack = msgs(conn).last
    assert_equal false, ack["ok"]
    assert_equal "no_session", ack["error"]
  end

  def test_action_without_client_field_stays_trusted_local
    srv = mk_server(StubBunker.new(enabled: true, sessions: []))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "action", "id" => "a3", "name" => "post_note",
                                "params" => { "text" => "hi" } })
    assert_equal true, msgs(conn).last["ok"]
  end

  def test_action_malformed_client_is_rejected
    srv = mk_server(StubBunker.new(enabled: true, sessions: [CLIENT]))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "action", "id" => "a4", "name" => "post_note",
                                "params" => { "text" => "hi" }, "client" => "zz" })
    ack = msgs(conn).last
    assert_equal false, ack["ok"]
    assert_equal "no_session", ack["error"]
  end

  def test_bunker_disabled_actions_unchanged
    srv = mk_server(StubBunker.new(enabled: false, sessions: []))
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "action", "id" => "a5", "name" => "post_note",
                                "params" => { "text" => "hi" }, "client" => "d" * 64 })
    assert_equal true, msgs(conn).last["ok"]
  end
end
