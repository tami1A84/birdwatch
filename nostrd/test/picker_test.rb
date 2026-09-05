# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_core/relay_picker"

class PickerTest < Minitest::Test
  def setup
    @t = 1_700_000_000
    @picker = NostrCore::RelayPicker.new(num_relays_per_person: 2, max_relays: 3, now: -> { @t })
    # alice loves A and B; bob loves B and C; carol loves A and C
    @picker.add_someone("alice", [["wss://a", 1.0], ["wss://b", 0.8]])
    @picker.add_someone("bob", [["wss://b", 1.0], ["wss://c", 0.9]])
    @picker.add_someone("carol", [["wss://a", 0.7], ["wss://c", 0.6]])
  end

  def test_greedy_pick_covers_the_most_people_first
    first = @picker.pick
    # scoreboard: a = 1.0 + 0.7 = 1.7, b = 0.8 + 1.0 = 1.8, c = 0.9 + 0.6 = 1.5
    assert_equal "wss://b", first
    assert_equal %w[bob alice].sort, @picker.assignments["wss://b"].sort
    assert_equal 1, @picker.pubkey_counts["bob"]
  end

  def test_pick_all_covers_everyone
    picks = @picker.pick_all
    assert_equal 3, picks.size
    @picker.pubkey_counts.each_value { |c| assert_equal 0, c }
  end

  def test_penalty_box_excludes_then_releases
    @picker.pick_all
    @t += 10
    @picker.relay_disconnected("wss://b", 60)
    assert @picker.excluded.key?("wss://b")
    # bob and alice need reassignment; b is excluded so a/c win
    @picker.pick
    assert @picker.assignments.keys.none?("wss://b")
    @t += 120
    @picker.pick # pruning happens on pick
    assert_nil @picker.excluded["wss://b"] # expired and pruned on next pick
  end

  def test_garbage_collect_drops_unfollowed_and_idle_relays
    @picker.pick_all
    idle = @picker.garbage_collect(%w[alice bob]) # carol unfollowed
    assert_empty @picker.person_scores.keys & %w[carol]
    @picker.assignments.each_value { |pks| assert pks.all? { |pk| %w[alice bob].include?(pk) } }
    assert_kind_of Array, idle
  end

  def test_junk_floor_keeps_weak_tail_relays_unassigned
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 10, now: -> { @t })
    picker.add_someone("dave", [["wss://good", 1.0], ["wss://junk", 0.01]])
    picker.pick
    assert_equal %w[wss://good], picker.assignments.keys
    assert_equal 0, picker.pubkey_counts["dave"]
  end
end
