# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/orchestrator"
require_relative "relay_pool_test"

# Simulates the RelayPool handshake-gate failure path: connect() fires
# on_disconnect synchronously (drop with penalty) before raising.
class DeadlockPool
  attr_reader :dialed, :connections

  def initialize
    @dialed = []
    @connections = {}
    @on_disconnect = nil
  end

  def on_disconnect=(cb)
    @on_disconnect = cb
  end

  def connect(url)
    @dialed << url
    @on_disconnect&.call(url, 300)
    raise "handshake failed or timed out"
  end

  def subscribe_person(*)
    false # not connected yet
  end

  def subscribe_home(*)
    false
  end

  def refresh_home(*)
    false
  end

  def transmit_close(*); end

  def seek_relay_list(*)
    false
  end

  def seek_profile(*)
    false
  end
end

class OrchestratorTest < Minitest::Test
  def setup
    @t = 1_700_000_000
    @now = -> { @t }
    @store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    @pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(url, ev) { @orch&.ingest(url, ev) },
      on_disconnect: ->(url, penalty) { @orch&.relay_failed(url) }
    )
    @orch = Nostrd::Orchestrator.new(store: @store, picker: picker, pool: @pool, now: @now)
  end

  # Gossip switches: seeding from the published NIP-65 list, dependency
  # merge (inbox=>read, outbox=>write), and the advertise payload.
  def test_relay_switch_seed_flags_and_advertise
    me = "ab" * 32
    @store.upsert_event(Struct.new(:id, :pubkey, :created_at, :kind, :content, :tags)
                        .new("r10002", me, @t, 10002, "",
                             [["r", "wss://rw"], ["r", "wss://w", "w"]]))
    orch = Nostrd::Orchestrator.new(store: @store, picker: @picker, pool: @pool,
                                    my_pubkey: me, now: @now)
    # Seeded: published read+write -> inbox on; write-only -> outbox on.
    rw = @store.my_relay("wss://rw")
    assert_equal [true, true, true, true, false],
                 rw.values_at("read", "inbox", "write", "outbox", "discover")

    # Toggle inbox off; dependencies never force anything off implicitly.
    orch.set_relay_flags("wss://rw", read: true, inbox: false, write: true,
                         outbox: false, discover: true)
    assert_equal false, @store.my_relay("wss://rw")["inbox"]

    # Advertise payload: inbox => advertised read, outbox => write, both => nil.
    orch.set_relay_flags("wss://rw", read: true, inbox: true, write: true,
                         outbox: true, discover: false)
    out = orch.advertised_relay_list
    assert_equal({ "url" => "wss://rw", "marker" => nil }, out.first)
    w = out.find { |r| r["url"] == "wss://w" }
    assert_equal "w", w["marker"]
  end

  def test_relay_list_arrival_creates_evidence_then_assignments
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @orch.ingest("wss://a", { "id" => "rl1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 10002, "content" => "",
                              "tags" => [["r", "wss://b", "w"], ["r", "wss://c"]] })
    @orch.tick
    scores = @store.best_relays_for("pk_alice")
    assert_equal "wss://b", scores.first[0] # write claim +1.0 beats read +1.0? b has claim too...
    assert @pool.connections["wss://b"].sent.any? { |f| JSON.parse(f)[0] == "REQ" }
  end

  def test_dial_failure_happens_outside_mutex_no_deadlock
    store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    pool = DeadlockPool.new
    orch = Nostrd::Orchestrator.new(store: store, picker: picker, pool: pool,
                                    now: @now, logger: File.open(File::NULL, "w"))
    pool.on_disconnect = ->(url, _pen) { orch.relay_failed(url) }

    orch.follow("pk_x")
    orch.ingest("wss://a", { "id" => "rl", "pubkey" => "pk_x", "created_at" => @t,
                             "kind" => 10002, "content" => "",
                             "tags" => [["r", "wss://bad", "w"]] })
    orch.tick # drives the dial; must not raise ThreadError (recursive locking)

    assert_equal ["wss://bad"], pool.dialed
    orch.tick # penalty box keeps the failed relay out: no retry dial
    assert_equal ["wss://bad"], pool.dialed
  end

  def test_self_relay_list_seek_and_write_relays
    store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    orch = Nostrd::Orchestrator.new(store: store, picker: picker, pool: @pool,
                                    my_pubkey: "me", now: @now,
                                    logger: File.open(File::NULL, "w"))
    @pool.connect("wss://a")
    orch.tick
    reqs = @pool.connections["wss://a"].sent.filter_map { |f| j = JSON.parse(f); j if j[0] == "REQ" }
    assert reqs.any? { |r| r[2]["authors"] == ["me"] && r[2]["kinds"] == [10002] }

    orch.ingest("wss://a", { "id" => "own1", "pubkey" => "me", "created_at" => @t,
                             "kind" => 10002, "content" => "",
                             "tags" => [["r", "wss://w1", "w"], ["r", "wss://r1", "r"]] })
    assert_equal ["wss://w1"], orch.write_relays
  end

  def test_self_contact_list_seek_and_follow_merge
    store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    orch = Nostrd::Orchestrator.new(store: store, picker: picker, pool: @pool,
                                    my_pubkey: "me", now: @now,
                                    logger: File.open(File::NULL, "w"))
    @pool.connect("wss://a")
    orch.tick
    reqs = @pool.connections["wss://a"].sent.filter_map { |f| j = JSON.parse(f); j if j[0] == "REQ" }
    assert reqs.any? { |r| r[2]["authors"] == ["me"] && r[2]["kinds"] == [3] },
           "own kind 3 (contact list) must be seeked"

    # Own contact list arrives: p-tag pubkeys are adopted and persisted;
    # malformed p tags are dropped.
    pk_a = "aa" * 32
    pk_b = "bb" * 32
    orch.ingest("wss://a", { "id" => "c1", "pubkey" => "me", "created_at" => @t,
                             "kind" => 3, "content" => "",
                             "tags" => [["p", pk_a], ["p", pk_b], ["p", "xy"]] })
    assert_equal [pk_a, pk_b], (orch.followed & [pk_a, pk_b]).sort
    assert_equal [pk_a, pk_b], store.follows
    # Adoption drives the gossip machinery: their relay lists get seeked.
    reqs = @pool.connections["wss://a"].sent.filter_map { |f| j = JSON.parse(f); j if j[0] == "REQ" }
    assert reqs.any? { |r| r[2]["authors"] == [pk_a] && r[2]["kinds"] == [10002] }
  end

  def test_self_relay_list_ingest_dials_write_relays
    store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    orch = Nostrd::Orchestrator.new(store: store, picker: picker, pool: @pool,
                                    my_pubkey: "me", now: @now,
                                    logger: File.open(File::NULL, "w"))
    @pool.connect("wss://a")
    orch.ingest("wss://a", { "id" => "own1", "pubkey" => "me", "created_at" => @t,
                             "kind" => 10002, "content" => "",
                             "tags" => [["r", "wss://w1", "w"], ["r", "wss://r1", "r"]] })
    orch.tick # flushes the write-relay dial queued by learn_relay_list
    assert @pool.connections.key?("wss://w1")
  end

  def test_seeks_send_one_relay_per_try_politeness
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @orch.tick
    reqs = ->(url) {
      t = @pool.connections[url]
      ((t&.sent) || []).filter_map { |f| j = JSON.parse(f); j[0] == "REQ" ? j : nil }
    }
    a_has = reqs.call("wss://a").any? { |r| r[2]["authors"] == ["pk_alice"] && r[2]["kinds"] == [10002] }
    b_has = reqs.call("wss://b").any? { |r| r[2]["authors"] == ["pk_alice"] && r[2]["kinds"] == [10002] }
    assert a_has ^ b_has, "one relay per try (a=#{a_has} b=#{b_has}) — no fan-out"
  end

  def test_self_person_stream_without_following_self
    store = Nostrd::Store.new(":memory:")
    picker = NostrCore::RelayPicker.new(num_relays_per_person: 1, max_relays: 5, now: @now)
    orch = Nostrd::Orchestrator.new(store: store, picker: picker, pool: @pool,
                                    my_pubkey: "me", now: @now,
                                    logger: File.open(File::NULL, "w"))
    @pool.connect("wss://a")
    # Own 10002 arrives -> own write relay evidence -> own kind 1 stream.
    orch.ingest("wss://a", { "id" => "own1", "pubkey" => "me", "created_at" => @t,
                             "kind" => 10002, "content" => "",
                             "tags" => [["r", "wss://a", "w"]] })
    orch.tick
    reqs = @pool.connections["wss://a"].sent.filter_map { |f| j = JSON.parse(f); j if j[0] == "REQ" }
    assert reqs.any? { |r| r[2]["authors"] == ["me"] && r[2]["kinds"] == [1, 7, 1111] },
           "own notes must stream without having to follow yourself"
    assert_includes orch.persons, "me"
  end

  def test_events_flow_into_store_and_fetch_evidence
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @orch.ingest("wss://a", { "id" => "n1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 1, "content" => "hello", "tags" => [] })
    refute_nil @store.find_event("n1")
    # a plain fetch must not claim a relay list arrived
    assert_nil @store.newest_relay_list_at("pk_alice")
  end

  def test_kind0_ingest_stores_profile_and_newest_wins
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @orch.ingest("wss://a", { "id" => "m2", "pubkey" => "pk_alice", "created_at" => @t + 10,
                              "kind" => 0, "content" => '{"name":"Alice","nip05":"alice@zaps.lol"}',
                              "tags" => [] })
    prof = @store.profile_for("pk_alice")
    assert_equal "Alice", prof["name"]
    assert_equal "alice@zaps.lol", prof["nip05"]

    # an older metadata replay must not clobber the newer profile
    @orch.ingest("wss://a", { "id" => "m1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 0, "content" => '{"name":"Old"}', "tags" => [] })
    assert_equal "Alice", @store.profile_for("pk_alice")["name"]
  end

  def test_profile_seek_fans_out_then_backs_off
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @orch.tick
    kinds = @pool.connections["wss://a"].sent.filter_map do |f|
      j = JSON.parse(f)
      j[0] == "REQ" ? j[2]["kinds"] : nil
    end
    assert_includes kinds, [0], "profile (kind 0) seek sent to connected relays"

    # fresh arrival + backoff: the next tick must not re-seek
    @orch.ingest("wss://a", { "id" => "m1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 0, "content" => '{"name":"Alice"}', "tags" => [] })
    sent_before = @pool.connections["wss://a"].sent.size
    @orch.tick
    assert_equal sent_before, @pool.connections["wss://a"].sent.size
  end

  # A person's kind 0 lives on THEIR relays: the seek must try those first,
  # not walk connected relays alphabetically (that is why names stayed hex).
  def test_profile_seek_prefers_person_write_relays
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://w")
    @orch.ingest("wss://a", { "id" => "rl1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 10002, "content" => "",
                              "tags" => [["r", "wss://w", "w"]] })
    # write claim must sort ahead of the empirical fetch on wss://a
    assert_equal "wss://w", @store.person_relay_urls("pk_alice").first

    @orch.tick
    prof_on = @pool.connections.filter_map do |url, t|
      url if ((t&.sent) || []).any? do |f|
        j = JSON.parse(f)
        j[0] == "REQ" && j[2]["kinds"] == [0]
      end
    end
    assert_equal ["wss://w"], prof_on, "kind 0 seek goes to the person's write relay"
  end

  # Profile sync is ONE batched authors-REQ per try: hits one relay, then
  # rotates on the next batch. Missing profiles keep rotating until found.
  def test_profile_batch_seek_rotates_across_relays
    people = (1..6).map { |i| "pk_#{i}" }
    @orch.follow(*people)
    @pool.connect("wss://a")
    @pool.connect("wss://b")

    @orch.tick
    reqs_a = @pool.connections["wss://a"].sent.filter_map do |f|
      j = JSON.parse(f)
      j[0] == "REQ" && j[2]["kinds"] == [0] ? j[2] : nil
    end
    assert_equal 1, reqs_a.size, "one batch REQ per tick"
    assert_equal people.sort, reqs_a.first["authors"].sort, "all stale authors in one REQ"

    @t += 300 # first batch had no yield -> 2min backoff passed
    @orch.tick
    reqs_b = @pool.connections["wss://b"].sent.filter_map do |f|
      j = JSON.parse(f)
      j[0] == "REQ" && j[2]["kinds"] == [0] ? j[2] : nil
    end
    assert_equal 1, reqs_b.size, "next batch rotates to the other relay"
  end

  # An empty kind 0 (metadata-less content) must NOT mark the person fresh —
  # otherwise the name stays hex forever. A rich one silences the seek.
  def test_empty_kind0_keeps_seeking_rich_kind0_stops_it
    @orch.follow("pk_alice")
    @pool.connect("wss://a")

    @orch.tick
    count = -> {
      @pool.connections["wss://a"].sent.count do |f|
        j = JSON.parse(f)
        j[0] == "REQ" && j[2]["kinds"] == [0]
      end
    }
    assert_equal 1, count.call

    @t += 300
    @orch.ingest("wss://a", { "id" => "m0", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 0, "content" => "{}", "tags" => [] })
    @orch.tick
    assert_equal 2, count.call, "empty metadata must be retried elsewhere"

    @t += 400
    @orch.ingest("wss://a", { "id" => "m1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 0, "content" => '{"name":"Alice"}', "tags" => [] })
    @orch.tick
    assert_equal 2, count.call, "rich profile arrived: no more seeks"
  end

  def test_relay_failure_reassigns_subscriptions
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @orch.ingest("wss://a", { "id" => "rl1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 10002, "content" => "",
                              "tags" => [["r", "wss://a"], ["r", "wss://b"]] })
    @orch.tick
    assert @pool.connections.key?("wss://a")
    @pool.connections["wss://a"].fire_close
    @orch.tick
    # alice reassigned to wss://b; wss://a is in the penalty box
    assert @pool.connections.key?("wss://b")
    assert @pool.connections["wss://b"].sent.any? { |f| JSON.parse(f)[0] == "REQ" }
  end

  # Gossip model (mikedilger.com/gossip-model): a person's events are
  # fetched from their best ~3 relays — the picker's assignments — not from
  # every connected relay. An assignment relay streams ONLY its assigned
  # people; a discovered relay with no assignment loses its home stream and
  # is hung up entirely (connections exist to fetch people, not for their
  # own sake).
  def test_home_streams_follow_assignments_not_connectivity
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @orch.ingest("wss://a", { "id" => "rl1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 10002, "content" => "",
                              "tags" => [["r", "wss://b", "w"]] })
    @orch.tick
    home_req = lambda { |url|
      (@pool.connections[url]&.sent || []).filter_map do |f|
        j = JSON.parse(f)
        j if j[0] == "REQ" && j[1] == "home"
      end
    }
    b_req = home_req.call("wss://b").last
    assert_equal ["pk_alice"], b_req[2]["authors"], "assigned relay streams its person"

    assert_empty home_req.call("wss://a"), "unassigned relay gets no home stream"
    refute @pool.connections.key?("wss://a"), "purposeless discovered relay is hung up"
  end

  # Fresh-store floor: with zero assignments every person is "uncovered"
  # and rides the open connections — nothing is hung up, the timeline works
  # while evidence bootstraps, and the net narrows as assignments appear.
  def test_no_assignments_yet_keeps_all_connections
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @orch.tick # no relay lists anywhere: no assignments, no hang-ups
    assert @pool.connections.key?("wss://a")
    assert @pool.connections.key?("wss://b")
    # ...and uncovered people stream everywhere, so the timeline works.
    home = (@pool.connections.values).any? do |t|
      ((t&.sent) || []).any? do |f|
        (j = JSON.parse(f)) && j[0] == "REQ" && j[1] == "home"
      end
    end
    assert home, "some relay still streams the timeline"
  end

  # Loopback relay: streams EVERY person (it is our own store of record),
  # replays nothing (since = boot time), never penalty-boxes, and its
  # fetches are not relay evidence.
  def test_local_relay_streams_all_persons_since_boot
    @orch.local_relay_url = "ws://127.0.0.1:7777"
    @orch.follow("pk_alice")
    @pool.connect("ws://127.0.0.1:7777")
    @orch.tick
    req = @pool.connections["ws://127.0.0.1:7777"].sent.filter_map do |f|
      j = JSON.parse(f)
      j if j[0] == "REQ" && j[1] == "home"
    end.last
    assert_equal ["pk_alice"], req[2]["authors"]
    assert_equal @orch.booted_at, req[2]["since"], "no store replay over loopback"
  end

  def test_loopback_failure_never_penalty_boxes
    @orch.local_relay_url = "ws://127.0.0.1:7777"
    picker = @orch.instance_variable_get(:@picker)
    @orch.relay_failed("ws://127.0.0.1:7777")
    assert_empty picker.excluded, "loopback dials retry next tick, no 300s box"
    @orch.relay_failed("wss://net")
    assert_equal @t + 300, picker.excluded["wss://net"], "network relays keep the box"
  end

  def test_loopback_fetches_are_not_evidence
    @orch.local_relay_url = "ws://127.0.0.1:7777"
    @orch.follow("pk_alice")
    @orch.ingest("ws://127.0.0.1:7777", { "id" => "n9", "pubkey" => "pk_alice",
                                          "created_at" => @t, "kind" => 1,
                                          "content" => "hi", "tags" => [] })
    assert_empty @store.best_relays_for("pk_alice"),
                 "serving our own store says nothing about where a person posts"
  end

  # Profile batches fan over several relays per try (a single relay rarely
  # knows all 100 authors) and NEVER ask the loopback: it mirrors our own
  # store, so a "hit" there would be stale data and a miss starts the
  # backoff clock — names crawled in at boot because it sat first in the
  # sorted candidate rotation.
  def test_profile_batch_fans_out_and_skips_loopback
    @orch.local_relay_url = "ws://127.0.0.1:7777"
    %w[ws://127.0.0.1:7777 wss://a wss://b wss://c].each { |u| @pool.connect(u) }
    @orch.follow("pk_alice") # no profile in the store: stale, triggers a batch

    sent = @pool.connections.map do |url, t|
      [url, t.sent.filter_map { |f|
        j = JSON.parse(f)
        j if j[0] == "REQ" && j[1].start_with?("prof")
      }]
    end
    assert_empty sent.assoc("ws://127.0.0.1:7777").last,
                 "the loopback is never asked for profiles"
    fanned = sent.select { |_, reqs| reqs.any? }
    assert_equal %w[wss://a wss://b wss://c], fanned.map(&:first).sort,
                 "one batch fans over PROFILE_FANOUT relays"
    sub_ids = fanned.flat_map { |_, reqs| reqs.map { |j| j[1] } }
    assert_equal %w[prof0x0 prof0x1 prof0x2], sub_ids.sort
  end

  def test_relay_status_exposes_gossip_coverage
    @orch.follow("pk_alice")
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @orch.ingest("wss://a", { "id" => "rl1", "pubkey" => "pk_alice", "created_at" => @t,
                              "kind" => 10002, "content" => "",
                              "tags" => [["r", "wss://b", "w"]] })
    @orch.tick
    b = @orch.relay_status.find { |r| r["url"] == "wss://b" }
    assert_equal 1, b["covers"], "gossip rows report how many people they fetch"
    refute b["mine"]
    assert_nil @orch.relay_status.find { |r| r["url"] == "wss://a" },
               "the unassigned relay was hung up and leaves the panel"
  end
end
