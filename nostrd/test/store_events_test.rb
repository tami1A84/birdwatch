# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/store"

# event_exists? backs the LiveFeed fresh gate: relay replays of stored
# history must be recognized cheaply (primary-key SELECT) so they never
# reach clients — see the TUI-startup freeze fix.
class StoreEventsTest < Minitest::Test
  EV = Struct.new(:id, :pubkey, :created_at, :kind, :content, :tags)

  def test_event_exists_reflects_upserts
    store = Nostrd::Store.new(":memory:")
    assert !store.event_exists?("e1")

    store.upsert_event(EV.new("e1", "pk", 100, 1, "hello", []))
    assert store.event_exists?("e1")
    assert !store.event_exists?("e2")
  end

  def test_upsert_is_idempotent_so_replays_stay_new_false
    store = Nostrd::Store.new(":memory:")
    store.upsert_event(EV.new("e1", "pk", 100, 1, "hello", []))
    store.upsert_event(EV.new("e1", "pk", 100, 1, "hello", [])) # INSERT OR IGNORE
    assert store.event_exists?("e1")
    assert_equal 1, store.timeline(limit: 10).size
  end
end
