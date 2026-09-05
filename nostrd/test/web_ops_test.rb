# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/server"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostr_core/event"

# Ops added for the web client: follow/unfollow (+ kind 3 republish),
# delete_note (NIP-09), search, and the get extensions (thread/author/
# profile). Dispatched directly against a FakeConn like server_test.rb.
class FakeConn
  attr_reader :out

  def initialize = (@out = [])
  def puts(line) = (@out << line)
  def close = nil
end

class WebOpsTest < Minitest::Test
  ROOT = "a" * 64
  AUTHOR = "b" * 64
  ME = "c" * 64
  OTHER = "d" * 64

  def setup
    @now = 1_700_000_000
    @store = Nostrd::Store.new(":memory:")
    @root = mk_event(id: ROOT, pubkey: AUTHOR, kind: 1, content: "root note", created_at: @now, tags: [])
    @comment = mk_event(id: "e" * 64, pubkey: ME, kind: 1111, content: "a reply",
                        created_at: @now + 10,
                        tags: [["E", ROOT], ["K", "1"], ["P", AUTHOR],
                               ["e", ROOT], ["k", "1"], ["p", AUTHOR]])
    @reaction = mk_event(id: "f" * 64, pubkey: ME, kind: 7, content: "+",
                         created_at: @now + 20,
                         tags: [["e", ROOT], ["p", AUTHOR]])
    @other_note = mk_event(id: "g" * 64, pubkey: AUTHOR, kind: 1, content: "うんちの話",
                           created_at: @now + 5, tags: [])
  end

  def mk_server(signer: nil, publisher: nil, follows: [])
    Nostrd::Server.new(
      store: @store, socket_path: "/tmp/x.sock",
      signer: signer || ->(_name, _params) { { id: "signed" } },
      publisher: publisher || ->(_event) { ["wss://relay"] },
      info: -> { { "follows" => follows, "me" => ME, "relays" => [], "profiles" => [] } },
      follow: ->(pk) { (@followed ||= []) << pk },
      unfollow: ->(pk) { (@followed ||= []).delete(pk) }
    )
  end

  def msgs(conn) = conn.out.map { |l| JSON.parse(l) }

  def test_follow_op_publishes_contacts_and_acks
    srv = mk_server(follows: [OTHER, ME])
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "follow", "id" => "w1", "params" => { "pubkey" => OTHER } })
    ack = msgs(conn).last
    assert_equal "ack", ack["ev"]
    assert_equal true, ack["ok"]
    assert_equal "signed", ack["event_id"]
    assert_equal 1, ack["published_to"]
  end

  def test_follow_op_rejects_bad_pubkey
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "follow", "id" => "w1", "params" => { "pubkey" => "nope" } })
    frame = msgs(conn).last
    assert_equal "error", frame["ev"]
    assert_equal "bad_request", frame["code"]
  end

  def test_delete_note_signs_purges_and_acks
    @store.upsert_event(@root)
    signer_called = []
    srv = mk_server(signer: lambda { |name, params|
      signer_called << [name, params]
      { id: "del" }
    })
    conn = FakeConn.new
    srv.send(:dispatch, conn,
             { "op" => "delete_note", "id" => "w2",
               "params" => { "ids" => [ROOT, "9" * 64] } })
    ack = msgs(conn).last
    assert_equal true, ack["ok"]
    assert_equal 1, ack["deleted"] # unknown id skipped
    assert_equal "del", ack["event_id"]
    name, params = signer_called.first
    assert_equal "delete_note", name
    assert_equal [{ "id" => ROOT, "kind" => 1 }], params["targets"]
    assert_nil @store.find_event(ROOT)
  end

  def test_search_finds_notes_and_profiles
    @store.upsert_event(@other_note)
    @store.upsert_profile(NostrCore::Event.new(
      id: "p" * 64, pubkey: AUTHOR, kind: 0, created_at: @now,
      content: JSON.generate({ "name" => "tanaka", "nip05" => "t@example.com" }), tags: []
    ))
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "search", "id" => "w5", "params" => { "query" => "うんち" } })
    data = msgs(conn).last["data"]
    assert_equal ["g" * 64], data["notes"].map { |n| n[:id] || n["id"] }
    conn2 = FakeConn.new
    srv.send(:dispatch, conn2, { "op" => "search", "id" => "w6", "params" => { "query" => "tanaka" } })
    assert_equal [AUTHOR], msgs(conn2).last["data"]["profiles"].map { |p| p["pubkey"] }
  end

  def test_search_rejects_empty_query
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "search", "id" => "w5", "params" => { "query" => "  " } })
    assert_equal "bad_request", msgs(conn).last["code"]
  end

  def test_get_note_with_thread_scope
    @store.upsert_event(@root)
    @store.upsert_event(@comment)
    @store.upsert_event(@reaction)
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn,
             { "op" => "get", "id" => "w7", "kind" => "note",
               "params" => { "id" => ROOT, "scope" => "thread" } })
    data = msgs(conn).last["data"]
    assert_equal ROOT, data["note"]["id"]
    assert_equal ["e" * 64], data["comments"].map { |e| e["id"] }
    assert_equal ["f" * 64], data["reactions"].map { |e| e["id"] }
  end

  def test_get_note_flat_still_works
    @store.upsert_event(@root)
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "get", "id" => "w8", "params" => { "id" => ROOT } })
    data = msgs(conn).last["data"]
    assert_equal ROOT, data["id"]
  end

  def test_get_author_notes
    @store.upsert_event(@root)
    @store.upsert_event(@other_note)
    @store.upsert_event(@comment) # kind 1111 must not appear
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn,
             { "op" => "get", "id" => "w9", "kind" => "author",
               "params" => { "pubkey" => AUTHOR, "limit" => 10 } })
    data = msgs(conn).last["data"]
    assert_equal ["g" * 64, ROOT], data["notes"].map { |e| e["id"] }
  end

  def test_get_profile
    @store.upsert_profile(NostrCore::Event.new(
      id: "p" * 64, pubkey: AUTHOR, kind: 0, created_at: @now,
      content: JSON.generate({ "name" => "tanaka" }), tags: []
    ))
    srv = mk_server
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "get", "id" => "w10", "kind" => "profile",
                                "params" => { "pubkey" => AUTHOR } })
    assert_equal "tanaka", msgs(conn).last["data"]["profile"]["name"]
  end

  def test_timeline_includes_reactions_and_comments
    @store.upsert_event(@root)
    @store.upsert_event(@comment)
    @store.upsert_event(@reaction)
    kinds = @store.timeline(limit: 10).map(&:kind)
    assert_includes kinds, 7
    assert_includes kinds, 1111
    assert_includes kinds, 1
  end

  def test_store_remove_follow
    @store.save_follow(ME)
    assert_includes @store.follows, ME
    @store.remove_follow(ME)
    refute_includes @store.follows, ME
  end

  def test_purge_events
    @store.upsert_event(@root)
    @store.upsert_event(@comment)
    assert_equal 2, @store.purge_events([ROOT, @comment.id, "9" * 64])
    assert_nil @store.find_event(ROOT)
    assert_equal 0, @store.purge_events([])
  end

  private

  def mk_event(id:, pubkey:, kind:, content:, created_at:, tags:)
    NostrCore::Event.new(id: id, pubkey: pubkey, created_at: created_at,
                         kind: kind, content: content, tags: tags)
  end
end
