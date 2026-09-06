# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "json"
require_relative "../lib/nostrd/signer"
require_relative "../lib/nostrd/server"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostr_core/bip340"

# Raw signing is the one deliberate crack in the "actions only" vault
# boundary, so the allowlist and the socket ops get explicit coverage.
class RawSignTest < Minitest::Test
  FakeConn = Struct.new(:out) do
    def initialize = (self.out = [])
    def puts(line) = (out << line)
    def close = nil
  end

  def setup
    @dir = Dir.mktmpdir
    @signer = Nostrd::Signer.new(vault_path: File.join(@dir, "vault.bin"))
    @signer.create_key(passphrase: "opensesame")
  end

  def test_sign_raw_signs_vetted_kinds_only
    event = @signer.call("sign_raw", { "kind" => 35128, "content" => "",
                                       "tags" => [["d", "birdwatch"],
                                                  ["path", "/index.html", "a" * 64]] })
    assert_equal 35128, event[:kind]
    assert_equal @signer.pubkey, event[:pubkey]
    assert NostrCore::Bip340.verify([@signer.pubkey].pack("H*"), [event[:id]].pack("H*"),
                                    [event[:sig]].pack("H*"))

    [27235, 24242, 10063, 15128, 5128].each do |kind|
      @signer.call("sign_raw", { "kind" => kind, "content" => "", "tags" => [] })
    end

    [0, 1, 7, 20_001, "35128", nil].each do |bad_kind|
      e = assert_raises(ArgumentError) do
        @signer.call("sign_raw", { "kind" => bad_kind, "content" => "", "tags" => [] })
      end
      assert_includes e.message, "not raw-signable"
    end
  end

  def test_sign_raw_validates_shape
    assert_raises(ArgumentError) do
      @signer.call("sign_raw", { "kind" => 35128, "content" => "x",
                                 "tags" => "not-an-array" })
    end
    assert_raises(ArgumentError) do
      @signer.call("sign_raw", { "kind" => 35128, "content" => "",
                                 "tags" => [[1, 2]] })
    end
    assert_raises(ArgumentError) do
      @signer.call("sign_raw", { "kind" => 35128, "content" => nil, "tags" => [] })
    end
    assert_raises(ArgumentError) do
      @signer.call("sign_raw", { "kind" => 35128, "content" => "x" * 65 * 1024, "tags" => [] })
    end
  end

  def test_sign_raw_locked_signer_refuses
    @signer.lock
    e = assert_raises(RuntimeError) do
      @signer.call("sign_raw", { "kind" => 35128, "content" => "", "tags" => [] })
    end
    assert_equal "signer is locked", e.message
  end

  def server(signer: @signer, publisher: ->(_e) { ["wss://r"] })
    Nostrd::Server.new(store: Nostrd::Store.new(":memory:"),
                       socket_path: "/tmp/x.sock", signer: signer, publisher: publisher)
  end

  def test_sign_raw_op_replies_with_event
    conn = FakeConn.new
    server.send(:dispatch, conn, { "op" => "sign_raw", "id" => "r1",
                                   "params" => { "kind" => 15128, "content" => "",
                                                 "tags" => [["path", "/x", "b" * 64]] } })
    frame = JSON.parse(conn.out.last)
    assert_equal "result", frame["ev"]
    assert_equal 15128, frame.dig("data", "event", "kind")
  end

  def test_sign_raw_op_maps_errors_to_ack
    conn = FakeConn.new
    server.send(:dispatch, conn, { "op" => "sign_raw", "id" => "r2",
                                   "params" => { "kind" => 1, "content" => "", "tags" => [] } })
    frame = JSON.parse(conn.out.last)
    assert_equal "ack", frame["ev"]
    refute frame["ok"]
    assert_includes frame["error"], "not raw-signable"
  end

  def test_publish_raw_op_signs_and_publishes
    conn = FakeConn.new
    srv = server
    srv.send(:dispatch, conn, { "op" => "publish_raw", "id" => "p1",
                                "params" => { "kind" => 35128, "content" => "",
                                              "tags" => [["d", "birdwatch"]] } })
    frame = JSON.parse(conn.out.last)
    assert_equal "result", frame["ev"]
    assert_equal ["wss://r"], frame.dig("data", "published_to")
    assert_equal 35128, frame.dig("data", "event", "kind")
  end

  def test_publish_raw_op_without_publisher_is_an_error
    conn = FakeConn.new
    srv = server(publisher: nil)
    srv.send(:dispatch, conn, { "op" => "publish_raw", "id" => "p2",
                                "params" => { "kind" => 35128, "content" => "", "tags" => [] } })
    frame = JSON.parse(conn.out.last)
    assert_equal "ack", frame["ev"]
    assert_includes frame["error"], "not live"
  end
end
