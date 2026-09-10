# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/store"

# The wild advertises relays both as "wss://x" and "wss://x/". Everything
# keying a relay (pool, evidence store, picker) must land on one canonical
# url, or the same relay gets dialed and scored twice (TUI showed 11
# connections for 8 relays).
class StoreRelayUrlsTest < Minitest::Test
  def setup
    @store = Nostrd::Store.new(":memory:")
  end

  def test_normalize_strips_trailing_slashes
    assert_equal "wss://yabu.me", NostrCore.normalize_relay_url("wss://yabu.me/")
    assert_equal "wss://yabu.me", NostrCore.normalize_relay_url("wss://yabu.me///")
    assert_equal "wss://yabu.me", NostrCore.normalize_relay_url(" wss://yabu.me ")
    assert_equal "wss://yabu.me", NostrCore.normalize_relay_url("wss://yabu.me")
  end

  # Loopback fetches are not network evidence (the embedded relay serves
  # our own store): purged once at boot so it cannot crowd real relays out
  # of a person's top-3.
  def test_purge_loopback_evidence
    @store.record_fetch("ws://127.0.0.1:7777/", "pk_alice", 1_700_000_000)
    @store.record_fetch("wss://net", "pk_alice", 1_700_000_000)
    @store.purge_loopback_evidence("ws://127.0.0.1:7777")
    assert_equal ["wss://net"], @store.person_relay_urls("pk_alice")
  end

  def test_my_relay_roundtrip_normalizes_url
    @store.upsert_my_relay("wss://y/", read: true, inbox: false, write: true,
                           outbox: false, discover: false)
    assert_equal ["wss://y"], @store.my_relays.map { |r| r["url"] }
    # lookups with either spelling find the canonical row
    assert @store.my_relay("wss://y/")
    assert @store.my_relay("wss://y")
    @store.remove_my_relay("wss://y/")
    assert_empty @store.my_relays
  end

  def test_person_relay_list_stores_canonical_urls
    @store.upsert_person_relay_list("pk", [["r", "wss://y/", "w"], ["r", "wss://y"]], 100)
    @store.upsert_relay(NostrCore::Relay.new(url: "wss://y", rank: 9))
    # both spellings collapse onto one evidence row -> one scored relay
    scores = @store.best_relays_for("pk")
    assert_equal 1, scores.size
    assert_equal "wss://y", scores.first[0]
  end

  # Legacy stores already hold both spellings: read-side merge unions the
  # evidence (NIP-65 claim + empirical fetch) instead of double-counting.
  def test_best_relays_for_merges_legacy_slash_variants
    @store.upsert_relay(NostrCore::Relay.new(url: "wss://y/", rank: 9))
    @store.instance_variable_get(:@db).execute(
      "INSERT INTO person_relays VALUES (?,?,?,?,?,?,?)", ["pk", "wss://y/", 1, 0, nil, nil, 100]
    )
    @store.record_fetch("wss://y", "pk", 200)

    now = 200
    url, score = @store.best_relays_for("pk", now: now).first
    assert_equal "wss://y", url
    assert_equal 1, @store.best_relays_for("pk", now: now).size

    # claim (1.0) + fresh fetch decay (0.2) = 1.2, × rank 9 unconnected (0.5/2)
    assert_in_delta 1.2 * 0.25, score, 1e-9
  end

  def test_relay_upsert_and_lookup_are_canonical
    @store.upsert_relay(NostrCore::Relay.new(url: "wss://y/", rank: 7))
    assert_equal 7, @store.relay("wss://y").rank
    assert_equal "wss://y", @store.relay("wss://y/").url
  end
end
