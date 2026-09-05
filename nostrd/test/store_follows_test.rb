# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/store"

# Follows survive restarts: --follow args land in the DB via
# Orchestrator#follow -> Store#save_follow, and bin/nostrd re-reads them.
class StoreFollowsTest < Minitest::Test
  def test_save_dedupe_and_list
    store = Nostrd::Store.new(":memory:")
    assert_empty store.follows
    store.save_follow("pk_b")
    store.save_follow("pk_a")
    store.save_follow("pk_b") # dedupe via PRIMARY KEY
    assert_equal %w[pk_a pk_b], store.follows
  end

  # NIP-65 marker parsing for the gossip-style relay panel: nil = read+write,
  # "w"/"r" narrow it; only the newest kind-10002 event counts.
  def test_relay_list_for_parses_nip65_markers
    store = Nostrd::Store.new(":memory:")
    me = "aa" * 32
    ev = Struct.new(:id, :pubkey, :created_at, :kind, :content, :tags)
    store.upsert_event(ev.new("e1", me, 100, 10002, "",
                              [["r", "wss://both.example"],
                               ["r", "wss://write.example", "w"],
                               ["r", "wss://read.example", "r"],
                               ["r", "https://ignored.example"]]))
    store.upsert_event(ev.new("e2", me, 200, 10002, "", [["r", "wss://latest.example"]]))

    list = store.relay_list_for(me)
    assert_equal ["wss://latest.example"], list.map { |r| r["url"] }
    assert list[0]["read"] && list[0]["write"]

    assert_empty store.relay_list_for("bb" * 32) # no list event
  end

  # Gossip switch state: defaults, merge with dependency rules, advertised
  # payload derivation.
  def test_my_relays_switches_and_advertised_list
    store = Nostrd::Store.new(":memory:")
    assert_empty store.my_relays

    store.upsert_my_relay("wss://a.example", read: true, inbox: true,
                          write: true, outbox: false, discover: false)
    r = store.my_relay("wss://a.example")
    assert_equal true, r["inbox"]
    assert_equal false, r["outbox"]

    # Advertised derivation happens in the orchestrator; here just verify
    # persistence round-trips all five switches.
    store.upsert_my_relay("wss://b.example", read: true, inbox: false,
                          write: true, outbox: true, discover: true)
    assert_equal %w[wss://a.example wss://b.example], store.my_relays.map { |x| x["url"] }
    assert_equal [true, false, true, true, true],
                 store.my_relay("wss://b.example").values_at("read", "inbox", "write", "outbox", "discover")
  end
end
