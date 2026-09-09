# frozen_string_literal: true

require "minitest/autorun"
require "securerandom"
require "tmpdir"
require "json"
require_relative "../lib/nostr_core/gift_wrap"
require_relative "../lib/nostrd/dm"
require_relative "../lib/nostrd/store"
require_relative "../lib/nostrd/server"
require_relative "../lib/nostrd/orchestrator"
require_relative "relay_pool_test" # StubTransport

# NIP-59 gift wrap: pure crypto roundtrip + tamper resistance.
class GiftWrapTest < Minitest::Test
  def setup
    @alice_sk, @alice_pk = mk_keys
    @bob_sk, @bob_pk = mk_keys
    @now = Time.now.to_i
  end

  def mk_keys
    sk = SecureRandom.bytes(32)
    [sk, NostrCore::Bip340.public_key(sk)]
  end

  def wrap(text = "psst, secret", to: @bob_pk)
    rumor = NostrCore::GiftWrap.chat_rumor(text, to: to, from: @alice_pk, subject: "hey")
    seal, gift = NostrCore::GiftWrap.wrap(rumor: rumor, sender_priv: @alice_sk,
                                          recipient_pub: to)
    [rumor, seal, gift]
  end

  def test_rumor_is_unsigned_kind14
    rumor, = wrap
    assert_equal 14, rumor["kind"]
    assert_equal @alice_pk, rumor["pubkey"]
    assert_equal [["p", @bob_pk], ["subject", "hey"]], rumor["tags"]
    assert_nil rumor["sig"]
    # id derivable from the NIP-01 serialization even without a signature
    expected = Digest::SHA256.hexdigest(
      NostrCore::Event.id_payload(rumor["pubkey"], rumor["created_at"], 14,
                                  rumor["tags"], rumor["content"])
    )
    assert_equal expected, rumor["id"]
  end

  def test_roundtrip_alice_to_bob
    rumor, seal, gift = wrap
    assert_equal 13, seal["kind"]
    assert_equal @alice_pk, seal["pubkey"]
    assert_equal 1059, gift["kind"]
    assert_equal [["p", @bob_pk]], gift["tags"]
    refute_equal seal["pubkey"], gift["pubkey"] # wrap rides a throwaway key

    # Both layers randomized within the last 2 days (NIP-59 metadata cover).
    [seal, gift].each do |e|
      assert_operator e["created_at"], :<=, @now
      assert_operator e["created_at"], :>, @now - 2 * 24 * 60 * 60
    end
    # Both layers signed (relays reject unsigned events).
    [seal, gift].each do |e|
      assert NostrCore::Bip340.verify([e["pubkey"]].pack("H*"), [e["id"]].pack("H*"),
                                      [e["sig"]].pack("H*"))
    end

    out = NostrCore::GiftWrap.unwrap(gift_wrap: gift, recipient_priv: @bob_sk)
    assert_equal rumor, out
    assert_equal "psst, secret", out["content"]
    assert_equal @alice_pk, out["pubkey"]
    assert_nil out["sig"]
  end

  def test_foreign_key_unwrap_is_nil
    carol_sk, carol_pk = mk_keys
    _, _, gift = wrap("for carol only", to: carol_pk)
    # Bob holds the wrong key: the conversation key differs, MAC fails.
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: gift, recipient_priv: @bob_sk)
    # The recipient's key decrypts.
    out = NostrCore::GiftWrap.unwrap(gift_wrap: gift, recipient_priv: carol_sk)
    assert_equal "for carol only", out["content"]
  end

  def test_tampered_gift_unwrap_is_nil
    _, _, gift = wrap
    # Flip one base64 byte inside the nonce region — NIP-44 MAC must reject.
    chars = gift["content"].chars
    chars[10] = chars[10] == "A" ? "B" : "A"
    gift["content"] = chars.join
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: gift, recipient_priv: @bob_sk)
  end

  def test_unwrap_rejects_bad_structure_and_garbage
    rumor, seal, gift = wrap
    refute_equal gift["kind"], seal["kind"]
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: seal, recipient_priv: @bob_sk)
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: {}, recipient_priv: @bob_sk)
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: nil, recipient_priv: @bob_sk)
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: rumor, recipient_priv: @bob_sk)
    # Locked signer (nil key) degrades to nil, never raises.
    assert_nil NostrCore::GiftWrap.unwrap(gift_wrap: gift, recipient_priv: nil)
  end

  def test_wrap_validates_inputs
    assert_raises(ArgumentError) do
      NostrCore::GiftWrap.chat_rumor("x", to: "nope", from: @alice_pk)
    end
    assert_raises(ArgumentError) do
      NostrCore::GiftWrap.wrap(rumor: { "kind" => 1 }, sender_priv: @alice_sk,
                               recipient_pub: @bob_pk)
    end
    assert_raises(ArgumentError) do
      NostrCore::GiftWrap.wrap(rumor: NostrCore::GiftWrap.chat_rumor("x", to: @bob_pk, from: @alice_pk),
                               sender_priv: "short", recipient_pub: @bob_pk)
    end
  end
end

# Daemon-side NIP-17 service: send (NIP-17 inbox-only publish + own rumor
# stored), receive (gift wrap → rumor in store), and history reads on a
# separate read-only SQLite connection.
class DmTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @alice_sk, @alice_pk = mk_keys
    @bob_sk, @bob_pk = mk_keys
    @carol_sk, @carol_pk = mk_keys
    @alice_db = File.join(@dir, "alice.db")
    @bob_db = File.join(@dir, "bob.db")
    @alice_store = Nostrd::Store.new(@alice_db)
    @bob_store = Nostrd::Store.new(@bob_db)
    @published = []
    @sign_and_publish = lambda do |rumor, to, relays|
      seal, gift = NostrCore::GiftWrap.wrap(rumor: rumor, sender_priv: @alice_sk,
                                            recipient_pub: to)
      @published << [gift, relays]
      { "seal" => seal, "gift" => gift, "published_to" => relays }
    end
    @alice = Nostrd::Dm.new(store: @alice_store, socket_db_path: @alice_db,
                            my_pubkey: @alice_pk, sign_and_publish: @sign_and_publish,
                            inbox_relays_for: ->(pk) { pk == @bob_pk ? ["wss://bob.inbox"] : [] },
                            seckey: @alice_sk)
    @bob = Nostrd::Dm.new(store: @bob_store, socket_db_path: @bob_db,
                          my_pubkey: @bob_pk, seckey: @bob_sk)
  end

  def mk_keys
    sk = SecureRandom.bytes(32)
    [sk, NostrCore::Bip340.public_key(sk)]
  end

  def test_send_dm_publishes_only_to_inbox_relays_and_stores_own_rumor
    out = @alice.send_dm("hello bob", to: @bob_pk)
    assert_match(/\A[0-9a-f]{64}\z/, out["event_id"])
    assert_equal 1, out["published_to"]

    gift, relays = @published.first
    assert_equal ["wss://bob.inbox"], relays # NIP-17: recipient inboxes ONLY
    assert_equal 1059, gift["kind"]

    rumor = @alice_store.find_event(out["event_id"])
    assert_equal 14, rumor.kind # our own chat history includes what we sent
    assert_equal "hello bob", rumor.content
  end

  def test_send_dm_validates
    assert_raises(ArgumentError) { @alice.send_dm("x", to: "nope") }
    assert_raises(ArgumentError) { @alice.send_dm("", to: @bob_pk) }
  end

  def test_end_to_end_alice_to_bob
    out = @alice.send_dm("hi from alice", to: @bob_pk)
    gift, _relays = @published.first

    rumor = @bob.handle_gift_wrap(gift, "wss://bob.inbox")
    assert_equal out["event_id"], rumor["id"]
    assert_equal "hi from alice", rumor["content"]

    stored = @bob_store.find_event(rumor["id"])
    assert_equal 14, stored.kind
    assert_equal @alice_pk, stored.pubkey

    # Both sides see the same thread from their own stores.
    thread = @bob.dms(partner: @alice_pk, limit: 50)["events"]
    assert_equal ["hi from alice"], thread.map { |e| e["content"] }
    mine = @alice.dms(partner: @bob_pk)["events"]
    assert_equal ["hi from alice"], mine.map { |e| e["content"] }
  end

  def test_handle_gift_wrap_ignores_foreign_and_garbage
    _, _, foreign = NostrCore::GiftWrap.wrap(
      rumor: NostrCore::GiftWrap.chat_rumor("to carol", to: @carol_pk, from: @alice_pk),
      sender_priv: @alice_sk, recipient_pub: @carol_pk
    )
    assert_nil @bob.handle_gift_wrap(foreign, "wss://x") # addressed to carol
    assert_nil @bob.handle_gift_wrap({ "kind" => 1059, "content" => "junk" }, "wss://x")
    assert_nil @bob.handle_gift_wrap(nil, "wss://x")
    # Locked signer: nothing decrypts, nothing stored.
    _, _, gift = NostrCore::GiftWrap.wrap(
      rumor: NostrCore::GiftWrap.chat_rumor("for bob", to: @bob_pk, from: @alice_pk),
      sender_priv: @alice_sk, recipient_pub: @bob_pk
    )
    locked = Nostrd::Dm.new(store: @bob_store, socket_db_path: @bob_db,
                            my_pubkey: @bob_pk, seckey: nil)
    assert_nil locked.handle_gift_wrap(gift, "wss://x")
    assert_empty @bob_store.timeline(limit: 100, kind: 14)
  end

  def test_dms_conversation_list
    @alice.send_dm("first to bob", to: @bob_pk)
    @alice.send_dm("second to bob", to: @bob_pk)
    @alice.send_dm("to carol", to: @carol_pk)

    convos = @alice.dms(limit: 10)["conversations"]
    assert_equal [@carol_pk, @bob_pk], convos.map { |c| c["pubkey"] } # newest first
    assert_equal 1, convos.first["count"]
    assert_equal "to carol", convos.first["last"]["content"]
    assert_equal 2, convos.last["count"]
    assert_equal "second to bob", convos.last["last"]["content"]
  end

  def test_dms_read_only_connection_sees_shared_db
    # The Dm history query opens its own readonly SQLite handle on the same
    # file the (WAL) store writes through — prove it sees committed rows.
    @alice.send_dm("wal check", to: @bob_pk)
    rows = @alice.dms(partner: @bob_pk)["events"]
    assert_equal 1, rows.size
    assert_equal "wal check", rows.first["content"]
  end
end

# Orchestrator wiring: inbox sub carries 1059, ingest routes kind 1059 to
# the Dm service, and the NIP-17 accessors behave.
class OrchestratorDmRoutingTest < Minitest::Test
  RecordingDm = Struct.new(:handled) do
    def initialize = (self.handled = [])
    def handle_gift_wrap(ev, url) = (handled << [ev, url]; "rumor")
  end

  def setup
    @t = 1_700_000_000
    @now = -> { @t }
    @store = Nostrd::Store.new(":memory:")
    @me, @me_sk = mk_keys
    @dm = RecordingDm.new
    @pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(url, ev) { @orch&.ingest(url, ev) },
      on_disconnect: ->(url, _penalty) { @orch&.relay_failed(url) }
    )
    @orch = Nostrd::Orchestrator.new(store: @store, picker: NostrCore::RelayPicker.new,
                                     pool: @pool, my_pubkey: @me, dm: @dm, now: @now)
    @pool.connect("wss://r.example")
    @orch.tick
  end

  def mk_keys
    sk = SecureRandom.bytes(32)
    [NostrCore::Bip340.public_key(sk), sk]
  end

  def reqs
    @pool.connections.values.flat_map(&:sent).filter_map do |line|
      msg = JSON.parse(line)
      msg[0] == "REQ" ? msg[2] : nil
    end
  end

  def test_inbox_subscription_carries_gift_wraps
    inbox = reqs.find { |f| f["kinds"].include?(1059) }
    assert_equal [@me], inbox["#p"]
    assert_equal [1, 7, 1059, 1111], inbox["kinds"].sort
  end

  def test_ingest_routes_1059_to_dm_and_skips_ciphertext
    gift = { "id" => "f" * 64, "pubkey" => "a" * 64, "created_at" => @t,
             "kind" => 1059, "content" => "ciphertext", "tags" => [["p", @me]] }
    @orch.ingest("wss://r.example", gift)
    assert_equal [gift], @dm.handled.map(&:first)
    assert_nil @store.find_event(gift["id"]) # ciphertext never enters the store
  end

  def test_inbox_relays_accessor_and_publish_path
    @orch.ingest("wss://r.example",
                 { "id" => "1" * 64, "pubkey" => @me, "created_at" => @t, "kind" => 10002,
                   "content" => "", "tags" => [["r", "wss://inbox.one"], ["r", "wss://out.one", "w"]] })
    # marker-less r-tag = read+write → inbox evidence; write-only is not.
    assert_equal ["wss://inbox.one"], @orch.inbox_relays_for(@me)

    event = { "id" => "2" * 64, "pubkey" => @me, "created_at" => @t,
              "kind" => 1059, "content" => "x", "tags" => [] }
    @orch.publish_to(["wss://inbox.one"], event)
    sent = @pool.connections["wss://r.example"].sent.last
    assert_includes sent, "1059" # EVENT frame went out
  end
end

# Socket protocol: send_dm op + dms channel, FakeConn style of web_ops_test.
class ServerDmOpsTest < Minitest::Test
  FakeConn = Struct.new(:out) do
    def initialize = (self.out = [])
    def puts(line) = (out << line)
    def close = nil
  end

  def setup
    @store = Nostrd::Store.new(":memory:")
    @dm_events = [{ "id" => "e" * 64, "pubkey" => "a" * 64, "created_at" => 1,
                    "kind" => 14, "content" => "hi", "tags" => [["p", "b" * 64]] }]
    @srv = Nostrd::Server.new(
      store: @store, socket_path: "/tmp/x.sock",
      send_dm: ->(_pk, _text) { { "event_id" => "r" * 64, "published_to" => 2 } },
      dms: lambda { |partner:, limit: 50|
        partner ? { "events" => @dm_events } : { "conversations" => [{ "pubkey" => partner.to_s, "count" => 0 }] }
      }
    )
  end

  def msgs(conn) = conn.out.map { |l| JSON.parse(l) }

  def test_send_dm_op_acks_like_other_write_ops
    conn = FakeConn.new
    @srv.send(:dispatch, conn,
              { "op" => "send_dm", "id" => "d1", "params" => { "pubkey" => "b" * 64, "text" => "yo" } })
    ack = msgs(conn).last
    assert_equal "ack", ack["ev"]
    assert_equal true, ack["ok"]
    assert_equal "r" * 64, ack["event_id"]
    assert_equal 2, ack["published_to"]
  end

  def test_send_dm_op_reports_failures
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock",
                             send_dm: ->(_pk, _text) { raise ArgumentError, "empty" })
    conn = FakeConn.new
    srv.send(:dispatch, conn,
             { "op" => "send_dm", "id" => "d2", "params" => { "pubkey" => "b" * 64, "text" => "hello" } })
    ack = msgs(conn).last
    assert_equal false, ack["ok"]
    assert_equal "empty", ack["error"]
  end

  def test_dms_channel_replays_thread_then_eod
    conn = FakeConn.new
    @srv.send(:dispatch, conn,
              { "op" => "sub", "id" => "dm", "channel" => "dms",
                "params" => { "partner" => "a" * 64 } })
    frames = msgs(conn)
    assert_equal "event", frames.first["ev"]
    assert_equal "dm", frames.first["sub"]
    assert_equal "hi", frames.first["event"]["content"]
    assert_equal "eod", frames.last["ev"]
  end

  def test_dms_channel_without_partner_lists_conversations
    conn = FakeConn.new
    @srv.send(:dispatch, conn, { "op" => "sub", "id" => "dm", "channel" => "dms" })
    frames = msgs(conn)
    assert_equal "conversations", frames.first["ev"]
    assert_equal 1, frames.first["conversations"].size
    assert_equal "eod", frames.last["ev"]
  end

  def test_dms_channel_without_service_still_eods
    srv = Nostrd::Server.new(store: @store, socket_path: "/tmp/x.sock")
    conn = FakeConn.new
    srv.send(:dispatch, conn, { "op" => "sub", "id" => "dm", "channel" => "dms" })
    assert_equal "eod", msgs(conn).last["ev"]
  end
end
