# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/live_feed"

module Nostrd
  class LiveFeedTest < Minitest::Test
    def setup
      @sent = []
      @feed = LiveFeed.new { |ev| @sent << ev }
    end

    def test_pushes_relay_events_of_kind_1_and_1111
      @feed.push({ "kind" => 1, "id" => "a", "content" => "note" })
      @feed.push({ "kind" => 7, "id" => "r", "content" => "+",
                   "tags" => [["e", "a"]] })
      @feed.push({ "kind" => 1111, "id" => "b", "content" => "comment" })
      assert_equal %w[a r b], @sent.map { |e| e["id"] } # kind 7 rides the feed for 👍 counts
    end

    def test_normalizes_symbol_keyed_own_events_before_broadcast
      @feed.push({ kind: 1111, id: "own", content: "self-echo", pubkey: "me" })
      assert_equal "own", @sent.dig(0, "id")
      assert_equal 1111, @sent.dig(0, "kind")
      assert_equal "self-echo", @sent.dig(0, "content")
      assert_equal "me", @sent.dig(0, "pubkey")
    end

    def test_drops_other_kinds_and_shapeless_input
      @feed.push({ "kind" => 0, "id" => "p" }) # profiles ride another frame
      @feed.push({ "kind" => 7 }) # reaction without id is shapeless -> dropped
      @feed.push({ "kind" => 1 }) # no id
      @feed.push("garbage")
      @feed.push(nil)
      assert_empty @sent
    end

    def test_suppresses_relay_echo_of_already_sent_event
      @feed.push({ kind: 1, id: "x", content: "mine" }) # self-echo first
      @feed.push({ "kind" => 1, "id" => "x", "content" => "relay echo" })
      assert_equal 1, @sent.size
    end

    def test_seen_cache_is_a_bounded_lru
      600.times { |i| @feed.push({ "kind" => 1, "id" => "e#{i}" }) }
      @feed.push({ "kind" => 1, "id" => "e0" }) # evicted long ago -> sent again
      @feed.push({ "kind" => 1, "id" => "e599" }) # still remembered -> suppressed
      assert_equal 601, @sent.size
    end
  end
end
