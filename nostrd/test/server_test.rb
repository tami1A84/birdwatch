# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/server"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostr_core/event"

# Collects NDJSON replies without a real unix socket; dispatch is exercised
# directly so the protocol stays testable headless.
class FakeConn
  attr_reader :out

  def initialize = (@out = [])
  def puts(line) = (@out << line)
  def close = nil
end

# Simulates a vanished client: every write records then fails.
class DeadConn
  attr_reader :out

  def initialize = (@out = [])
  def puts(line)
    @out << line
    raise Errno::EPIPE, "broken pipe"
  end
  def close = nil
end

class ServerTest < Minitest::Test
  def setup
    @now = 1_700_000_000
    @store = Nostrd::Store.new(":memory:")
    3.times do |i|
      @store.upsert_event(NostrCore::Event.new(id: "e#{i}", pubkey: "pk#{i % 2}",
                                               created_at: @now - i * 10, kind: 1,
                                               content: "note #{i}", tags: []))
    end
    @store.upsert_profile(NostrCore::Event.new(id: "p0", pubkey: "pk0", created_at: @now,
                                               kind: 0,
                                               content: JSON.generate({ "name" => "Alice" }),
                                               tags: []))
  end

  def msgs(conn) = conn.out.map { |l| JSON.parse(l) }

  def test_send_info_serves_profiles_with_follows
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock",
                             info: -> { { "follows" => ["pk0"], "relays" => [],
                                          "profiles" => [@store.profile_for("pk0")] } })
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "info", "id" => "i1" })
    frame = msgs(conn).last
    assert_equal "info", frame["ev"]
    assert_equal ["pk0"], frame["follows"]
    assert_equal "Alice", frame["profiles"].first["name"]
  end

  # relay_flags merges locally (lambda), advertise signs+publishes (lambda).
  def test_lock_op_locks_signer
    locked = false
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock",
                             lock: -> { locked = true })
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "lock", "id" => "l1" })
    frame = msgs(conn).last
    assert_equal true, locked
    assert_equal true, frame["ok"]
  end

  def test_relay_flags_and_advertise_ops
    seen = []
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock",
                             relay_flags: ->(p) { seen << p; p.merge("read" => true) },
                             advertise_relays: -> { { "relays" => [{ "url" => "wss://a", "marker" => nil }],
                                                     "event_id" => "evt1", "published_to" => 2 } })
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "relay_flags", "id" => "f1",
                                "params" => { "url" => "wss://a", "inbox" => true } })
    frame = msgs(conn).last
    assert_equal [true, "wss://a"], [frame["ok"], seen.first["url"]]

    conn2 = FakeConn.new
    srv.send(:dispatch, conn2, { "op" => "advertise_relays", "id" => "a1" })
    frame2 = msgs(conn2).last
    assert_equal ["evt1", 2], [frame2["event_id"], frame2["published_to"]]

    bad = FakeConn.new
    srv.send(:dispatch, bad, { "op" => "relay_flags", "id" => "f2",
                               "params" => { "url" => "https://nope" } })
    assert_equal false, msgs(bad).last["ok"]
  end

  def test_history_flag_caps_replay_client_limit_overrides
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock", history: 2)

    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    frames = msgs(conn)
    events = frames.select { |m| m["ev"] == "event" }
    assert_equal 2, events.size # --history 2 caps the replay
    assert_equal "e0", events.first["event"]["id"] # newest first (e0 = newest)
    assert_equal "e1", events.last["event"]["id"]

    # history -> profiles -> eod, in that order
    assert_operator frames.index { |m| m["ev"] == "profiles" }, :<,
                   frames.index { |m| m["ev"] == "eod" }
    assert_equal "Alice", frames.find { |m| m["ev"] == "profiles" }["profiles"].first["name"]

    # explicit client limit beats the daemon default
    conn2 = FakeConn.new
    srv.send(:dispatch, conn2, { "op" => "sub", "id" => "tl", "channel" => "timeline",
                                 "params" => { "limit" => 1 } })
    assert_equal 1, msgs(conn2).count { |m| m["ev"] == "event" }
  end

  def test_default_history_is_100
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock")
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    assert_equal 3, msgs(conn).count { |m| m["ev"] == "event" } # all 3 fit
  end

  # Live feed: after the eod, fresh events are pushed as {ev:event, sub:live},
  # followed by the author's profile frame (mirrors the history path).
  def test_broadcast_event_reaches_timeline_subscribers
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock", history: 100)
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    before = conn.out.size

    srv.broadcast_event({ "id" => "live1", "pubkey" => "pk0", "created_at" => @now + 5,
                          "kind" => 1, "content" => "fresh note", "tags" => [] })
    live = msgs(conn).drop(before)
    assert_equal "event", live.first["ev"]
    assert_equal "live", live.first["sub"]
    assert_equal "fresh note", live.first["event"]["content"]
    prof = live.find { |m| m["ev"] == "profiles" }
    assert_equal "Alice", prof["profiles"].first["name"]
  end

  def test_broadcast_skips_unsubscribed_and_prunes_dead_conns
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock")
    sub = FakeConn.new
    other = FakeConn.new # connected but never subscribed to timeline
    dead = DeadConn.new
    srv.send(:dispatch, sub, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    srv.send(:dispatch, dead, { "op" => "sub", "id" => "tl", "channel" => "timeline" })

    srv.broadcast_event({ "id" => "live2", "pubkey" => "pk1", "created_at" => @now + 5,
                          "kind" => 1, "content" => "x", "tags" => [] })
    assert_empty msgs(other) # no timeline sub -> no live frames
    assert msgs(sub).any? { |m| m["ev"] == "event" && m["event"]["id"] == "live2" }
  end

  # A kind 0 landing in the store (profile seek result) is pushed as a
  # standalone live profiles frame — names must appear without reconnecting.
  def test_broadcast_profile_pushes_stored_profile_to_listeners
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock")
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    before = conn.out.size

    @store.upsert_profile(NostrCore::Event.new(id: "p1", pubkey: "pk1", created_at: @now,
                                               kind: 0,
                                               content: JSON.generate({ "name" => "Bob" }),
                                               tags: []))
    srv.broadcast_profile("pk1")
    frame = msgs(conn).drop(before).last
    assert_equal "profiles", frame["ev"]
    assert_equal "live", frame["sub"]
    assert_equal "Bob", frame["profiles"].first["name"]
  end

  def test_broadcast_profile_stays_silent_without_usable_metadata
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock")
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "tl", "channel" => "timeline" })
    before = conn.out.size

    @store.upsert_profile(NostrCore::Event.new(id: "p2", pubkey: "pk2", created_at: @now,
                                               kind: 0, content: "{}", tags: []))
    srv.broadcast_profile("pk2") # stored, but no name/nip05/... -> skip
    srv.broadcast_profile("nobody") # unknown -> skip
    assert_equal before, conn.out.size
  end
end

class FakeOneShot
  attr_reader :calls

  def publish(url, event, auth: nil)
    @calls ||= []
    @calls << [url, event, auth]
    [true, "dup"]
  end
end

def test_announce_repo_op_publishes_directly_to_buzz_relay
  signed = { id: "ab" * 32, pubkey: "cd" * 32, kind: 30617, tags: [], content: "" }
  one = FakeOneShot.new
  srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock", signer: ->(_n, _p) { signed }, one_shot: one)
  conn = FakeConn.new
  srv.send(:dispatch, conn, { "op" => "announce_repo", "id" => "r1",
                              "params" => { "repo_id" => "birdwatch",
                                            "clone_urls" => ["https://github.com/tami1A84/birdwatch.git"] } })
  frame = msgs(conn).last
  url, event, auth = one.calls.first
  assert_equal "wss://png.communities.buzz.xyz", url # Buzz Desktop's baked relay
  assert_equal signed, event
  assert_nil auth # lambda signer has no auth_event
  assert_equal true, frame["ok"]
  assert_equal signed[:id], frame["event_id"]
  assert_equal "dup", frame["message"]

  # relay override lands on the caller's relay, not the default
  srv.send(:dispatch, FakeConn.new, { "op" => "announce_repo", "id" => "r2",
                                      "params" => { "repo_id" => "birdwatch", "clone_urls" => ["x"],
                                                    "relay" => "wss://other.example" } })
  assert_equal "wss://other.example", one.calls.last[0]
end
