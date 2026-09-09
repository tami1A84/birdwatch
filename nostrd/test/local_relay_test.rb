# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "digest"
require "securerandom"
require_relative "../lib/nostrd/local_relay"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostrd/ws_client"
require_relative "../lib/nostr_core/event"
require_relative "../lib/nostr_core/bip340"

# Unit tests drive LocalRelayTest::FakeConn through #handle_message (mirrors
# ServerTest's headless dispatch style, but nested to dodge that file's
# top-level FakeConn when the whole suite loads); the e2e test dials the
# relay with the real WsTransport client over localhost.
class LocalRelayTest < Minitest::Test
  # Same tiny registry API as LocalRelay::Conn.
  class FakeConn
    attr_reader :out, :subs

    def initialize
      @out = []
      @subs = {}
    end

    def send_text(text)
      @out << JSON.parse(text)
    end

    def close = nil

    def set_sub(sub_id, filters)
      @subs[sub_id] = { "filters" => filters, "live" => false }
    end

    def drop_sub(sub_id) = @subs.delete(sub_id)

    def mark_live(sub_id)
      @subs[sub_id]["live"] = true if @subs[sub_id]
    end

    def each_live_sub
      @subs.each { |sub_id, s| yield sub_id, s["filters"] if s["live"] }
    end
  end

  def setup
    @store = Nostrd::Store.new(":memory:")
    @sk = SecureRandom.random_bytes(32)
    @pk = NostrCore::Bip340.public_key(@sk)
    @relay = Nostrd::LocalRelay.new(store: @store, port: 0)
    @conn = FakeConn.new
    @seen = [] # every frame the e2e client received, in arrival order
  end

  # --- helpers ---

  def signed_event(content: "hello local relay", kind: 1, tags: [], seckey: @sk,
                   created_at: Time.now.to_i)
    pubkey = NostrCore::Bip340.public_key(seckey)
    id = Digest::SHA256.hexdigest(NostrCore::Event.id_payload(pubkey, created_at, kind, tags, content))
    sig = NostrCore::Bip340.sign([id].pack("H*"), seckey, SecureRandom.random_bytes(32))
    { "id" => id, "pubkey" => pubkey, "created_at" => created_at, "kind" => kind,
      "content" => content, "tags" => tags, "sig" => sig.unpack1("H*") }
  end

  def send!(conn, msg)
    @relay.send(:handle_message, conn, JSON.generate(msg))
  end

  # --- unit: EVENT validation ---

  def test_valid_event_is_stored_and_ok_true
    ev = signed_event
    send!(@conn, ["EVENT", ev])
    assert_equal ["OK", ev["id"], true, ""], @conn.out.last
    stored = @store.find_event(ev["id"])
    refute_nil stored
    assert_equal "hello local relay", stored.content
  end

  def test_bad_id_rejected
    ev = signed_event
    ev["id"] = "f" * 64
    send!(@conn, ["EVENT", ev])
    assert_equal ["OK", "f" * 64, false, @conn.out.last[3]], @conn.out.last
    assert_includes @conn.out.last[3], "id"
    assert_nil @store.find_event(ev["id"])
  end

  def test_bad_sig_rejected
    ev = signed_event # id is correct, signature is not
    ev["sig"] = "ab" * 64
    send!(@conn, ["EVENT", ev])
    assert_equal ["OK", ev["id"], false, @conn.out.last[3]], @conn.out.last
    assert_includes @conn.out.last[3], "signature"
    assert_nil @store.find_event(ev["id"])
  end

  def test_pubkey_outside_allowlist_rejected
    relay = Nostrd::LocalRelay.new(store: @store, allowed_pubkeys: ["a" * 64])
    ev = signed_event
    relay.send(:handle_message, @conn, JSON.generate(["EVENT", ev]))
    assert_equal ["OK", ev["id"], false, @conn.out.last[3]], @conn.out.last
    assert_includes @conn.out.last[3], "blocked"
    assert_nil @store.find_event(ev["id"])
  end

  def test_allowlisted_pubkey_accepted
    relay = Nostrd::LocalRelay.new(store: @store, allowed_pubkeys: [@pk])
    ev = signed_event
    relay.send(:handle_message, @conn, JSON.generate(["EVENT", ev]))
    assert_equal ["OK", ev["id"], true, ""], @conn.out.last
    refute_nil @store.find_event(ev["id"])
  end

  def test_duplicate_event_is_ok_true_and_idempotent
    ev = signed_event
    send!(@conn, ["EVENT", ev])
    send!(@conn, ["EVENT", ev])
    assert_equal ["OK", ev["id"], true, ""], @conn.out[-2]
    assert_equal ["OK", ev["id"], true, "duplicate:"], @conn.out.last
  end

  def test_malformed_input_gets_notice_and_connection_survives
    @relay.send(:handle_message, @conn, "this is not json")
    assert_equal "NOTICE", @conn.out.last[0]
    send!(@conn, ["EVENT", signed_event]) # same conn still works after garbage
    assert_equal ["OK", @conn.out.last[1], true, ""], @conn.out.last
  end

  def test_non_array_unknown_type_and_payloadless_event
    @relay.send(:handle_message, @conn, JSON.generate({ "EVENT" => {} }))
    @relay.send(:handle_message, @conn, JSON.generate(["BOGUS", 1]))
    send!(@conn, ["EVENT"]) # no payload -> OK false, not a crash
    assert_equal %w[NOTICE NOTICE OK], @conn.out.map { |m| m[0] }
    assert_equal false, @conn.out.last[2]
  end

  # --- unit: REQ over the store ---

  def test_req_streams_matches_then_eose
    send!(@conn, ["EVENT", (mine = signed_event(content: "mine"))])
    other = signed_event(content: "not mine", seckey: SecureRandom.random_bytes(32))
    send!(@conn, ["EVENT", other])
    send!(@conn, ["REQ", "s1", { "authors" => [@pk], "kinds" => [1] }])
    assert_equal %w[EOSE], @conn.out.last(1).map { |m| m[0] }
    ids = @conn.out.filter_map { |m| m[2]["id"] if m[0] == "EVENT" && m[1] == "s1" }
    assert_includes ids, mine["id"]
    refute_includes ids, other["id"]
  end

  def test_req_with_no_matches_is_just_eose
    send!(@conn, ["REQ", "empty", { "kinds" => [42] }])
    assert_equal ["EOSE", "empty"], @conn.out.last
  end

  def test_req_tag_and_time_filters
    root = "b" * 64
    send!(@conn, ["EVENT", (reply = signed_event(content: "reply", tags: [["e", root], ["p", @pk]],
                                                 created_at: 2000))])
    send!(@conn, ["EVENT", (solo = signed_event(content: "solo", created_at: 3000))])
    send!(@conn, ["REQ", "tag", { "#e" => [root] }])
    ids = @conn.out.last(2).filter_map { |m| m[2]["id"] if m[0] == "EVENT" && m[1] == "tag" }
    assert_equal [reply["id"]], ids
    assert_equal [["e", root], ["p", @pk]], @store.find_event(reply["id"]).tags # tags roundtrip intact
    send!(@conn, ["REQ", "win", { "since" => 2500 }])
    ids = @conn.out.last(2).filter_map { |m| m[2]["id"] if m[0] == "EVENT" && m[1] == "win" }
    assert_equal [solo["id"]], ids
  end

  def test_req_same_sub_id_replaces_and_close_drops
    send!(@conn, ["EVENT", signed_event])
    send!(@conn, ["REQ", "s", { "kinds" => [1] }])
    send!(@conn, ["REQ", "s", { "kinds" => [2] }])
    assert_equal [2], @conn.subs["s"]["filters"].first["kinds"] # replaced, not stacked
    send!(@conn, ["CLOSE", "s"])
    assert_nil @conn.subs["s"]
  end

  # --- unit: filter -> SQL logic (Store#relay_query) ---

  def test_relay_query_filter_logic
    mk = ->(c, pk, at, kind, tags) {
      NostrCore::Event.new(id: c * 64, pubkey: pk * 64, created_at: at, kind: kind,
                           content: "note #{c}", tags: tags)
    }
    e1 = mk.call("1", "a", 100, 1, [["e", "b" * 64]])
    e2 = mk.call("2", "a", 200, 3, [])
    e3 = mk.call("3", "c", 300, 1, [["p", "a" * 64]])
    [e1, e2, e3].each { |e| @store.upsert_event(e) }

    assert_equal %w[3 2 1], @store.relay_query({}).map { |e| e.id[0] } # newest first
    assert_equal %w[1], @store.relay_query({ "kinds" => [1], "authors" => ["a" * 64] }).map { |e| e.id[0] }
    assert_equal %w[2 1], @store.relay_query({ "until" => 200 }).map { |e| e.id[0] }
    assert_equal %w[2], @store.relay_query({ "since" => 101, "until" => 250 }).map { |e| e.id[0] }
    assert_equal %w[1], @store.relay_query({ "ids" => ["1" * 64] }).map { |e| e.id[0] }
    # OR across filters, deduped
    assert_equal %w[3 2], @store.relay_query([{ "kinds" => [3] }, { "authors" => ["c" * 64] }]).map { |e| e.id[0] }
    assert_equal 2, @store.relay_query({ "limit" => 2 }).size
    # junk values are ignored, never interpolated into SQL
    assert_equal 3, @store.relay_query({ "kinds" => ["nope"], "ids" => ["ZZ"] }).size

    # near-miss tag value: the needle's trailing quote must not match a
    # value that merely prefixes the target
    e4 = mk.call("4", "c", 400, 1, [["e", "b" * 63 + "f"]])
    @store.upsert_event(e4)
    hits = @store.relay_query({ "#e" => ["b" * 64] }).map(&:id)
    assert_includes hits, e1.id
    refute_includes hits, e4.id
    assert_equal %w[3], @store.relay_query({ "#p" => ["a" * 64] }).map { |e| e.id[0] }
  end

  # --- end to end: real WebSocket client over localhost ---

  def test_end_to_end_over_websocket
    relay = nil
    ws = nil
    begin
      relay = Nostrd::LocalRelay.new(store: @store, port: 0)
      relay.start
      assert relay.running?
      sk = SecureRandom.random_bytes(32)
      pk = NostrCore::Bip340.public_key(sk)
      frames = Queue.new
      ws = Nostrd::WsTransport.new("ws://127.0.0.1:#{relay.port}")
      ws.on_message { |data| frames << data }
      ws.open # blocks through the HTTP upgrade

      ev = signed_event(content: "e2e through the local relay", seckey: sk)
      ws.send_text(JSON.generate(["EVENT", ev]))
      ok = await_frame(frames) { |m| m[0] == "OK" }
      assert_equal ev["id"], ok[1]
      assert_equal [true, ""], ok.values_at(2, 3)
      refute_nil @store.find_event(ev["id"])

      ws.send_text(JSON.generate(["REQ", "t1", { "authors" => [pk], "kinds" => [1] }]))
      await_frame(frames) { |m| m[0] == "EOSE" && m[1] == "t1" }
      replayed = @seen.select { |m| m[0] == "EVENT" && m[1] == "t1" }.map { |m| m[2]["id"] }
      assert_includes replayed, ev["id"]

      # live push: subscribe, then publish — the fresh event arrives unasked
      ws.send_text(JSON.generate(["REQ", "live", { "authors" => [pk] }]))
      await_frame(frames) { |m| m[0] == "EOSE" && m[1] == "live" }
      ev2 = signed_event(content: "live push", seckey: sk, created_at: Time.now.to_i + 10)
      ws.send_text(JSON.generate(["EVENT", ev2]))
      push = await_frame(frames) { |m| m[0] == "EVENT" && m[1] == "live" && m[2]["id"] == ev2["id"] }
      assert_equal "live push", push[2]["content"]
      assert push[2]["sig"], "fresh broadcast carries the signature"
      await_frame(frames) { |m| m[0] == "OK" && m[1] == ev2["id"] } # may lag the push
    ensure
      ws&.close
      relay&.stop
    end
    refute relay.running?
  end

  def await_frame(queue, timeout: 15)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remain = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "timed out waiting for relay frame" if remain <= 0

      begin
        frame = JSON.parse(queue.pop(true))
      rescue ThreadError
        sleep 0.02
        next
      end
      @seen << frame
      return frame if yield(frame)
    end
  end
end
