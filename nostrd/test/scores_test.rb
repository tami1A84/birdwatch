# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_core/decay"
require_relative "../lib/nostr_core/person_relay"
require_relative "../lib/nostr_core/relay"

class ScoresTest < Minitest::Test
  def test_decay_halves_at_halflife
    base = 0.2
    assert_in_delta(base / 2, NostrCore::Decay.exponential(base, 100, 100), 1e-9)
    assert_in_delta(base, NostrCore::Decay.exponential(base, 100, 0), 1e-9)
    assert_equal 0.0, NostrCore::Decay.exponential(base, 100, -5)
  end

  def test_association_score_full_outbox_claim
    now = 1_700_000_000
    pr = NostrCore::PersonRelay.new(url: "wss://r", write: true, last_fetched: now)
    score = pr.association_score(now: now, usage: :outbox)
    # 1.0 (claim) + 0.2 (fresh evidence)
    assert_in_delta 1.2, score, 1e-9
  end

  def test_association_score_decays_and_respects_usage
    now = 1_700_000_000
    two_weeks = 14 * 24 * 3600
    pr = NostrCore::PersonRelay.new(url: "wss://r", write: true, read: true, last_fetched: now - two_weeks)
    outbox = pr.association_score(now: now, usage: :outbox)
    # 1.0 + 0.1 (half of 0.2 after one halflife)
    assert_in_delta 1.1, outbox, 1e-9
    inbox = pr.association_score(now: now, usage: :inbox)
    # no read claim missing? read=true so: 1.0 + 0.1
    assert_in_delta 1.1, inbox, 1e-9
    # stale suggested-only evidence is weak
    old = NostrCore::PersonRelay.new(url: "wss://r", last_suggested: now - 7 * 24 * 3600)
    assert_in_delta 0.05, old.association_score(now: now, usage: :outbox), 1e-9
  end

  def test_relay_score_rank_and_success_rate
    perfect = NostrCore::Relay.new(url: "wss://x", rank: 9, success_count: 10, successes: 10, connected: true)
    assert_in_delta 1.0, perfect.score, 1e-9

    half = NostrCore::Relay.new(url: "wss://x", rank: 9, success_count: 10, successes: 5)
    assert_in_delta 0.75, half.score, 1e-9

    # Low attempts are NOT penalized — new relays may establish.
    fresh = NostrCore::Relay.new(url: "wss://x", rank: 9)
    assert_in_delta 0.5, fresh.score, 1e-9

    # Unconnected relays halve their adjusted score.
    dark = NostrCore::Relay.new(url: "wss://x", rank: 9, success_count: 10, successes: 10, connected: false)
    assert_in_delta dark.score / 2, dark.adjusted_score, 1e-9
    assert_equal dark.score, perfect.adjusted_score
    assert_predicate perfect, :connected?
  end
end
