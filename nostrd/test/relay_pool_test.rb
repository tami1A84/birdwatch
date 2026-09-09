# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostrd/relay_pool"
require_relative "../lib/nostr_core/subscription"

class StubTransport
  attr_reader :sent
  attr_accessor :closed

  def initialize(url) = (@url = url)
  def on_message(&b) = (@message_cb = b)
  def on_close(&b) = (@close_cb = b)
  def open = true
  def send_text(text) = ((@sent ||= []) << text)
  def close = (@closed = true)
  def url = @url
  def fire_message(data) = @message_cb&.call(data)
  def fire_close = @close_cb&.call
end

class RelayPoolTest < Minitest::Test
  def setup
    @events = []
    @dropped = []
    @pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(url, ev) { @events << [url, ev] },
      on_disconnect: ->(url, penalty) { @dropped << [url, penalty] }
    )
  end

  def test_subscription_builders
    assert_equal ["REQ", "s1", { authors: %w[pk], kinds: [10002], limit: 1 }],
                 NostrCore::Subscription.seek_relay_list("s1", "pk")
    assert_equal ["REQ", "s2", { authors: %w[pk], kinds: [0], limit: 1 }],
                 NostrCore::Subscription.seek_profile("s2", "pk")
    assert_equal ["REQ", "s3", { authors: %w[pk], kinds: [3], limit: 1 }],
                 NostrCore::Subscription.seek_contact_list("s3", "pk")
    assert_equal ["CLOSE", "s1"], NostrCore::Subscription.close("s1")
  end

  def test_connect_subscribe_and_receive
    @pool.connect("wss://r.example")
    assert @pool.subscribe_person("wss://r.example", "s1", "pk_alice")
    sent = JSON.parse(@pool.connections["wss://r.example"].sent.last)
    assert_equal "REQ", sent[0]
    assert_equal "pk_alice", sent[2]["authors"].first
    assert_equal [1, 7, 1111], sent[2]["kinds"] # notes + NIP-22 comments stream live

    @pool.connections["wss://r.example"].fire_message(
      JSON.generate(["EVENT", "s1", { "id" => "e1", "pubkey" => "pk_alice", "created_at" => 1,
                                       "kind" => 1, "content" => "hi", "tags" => [] }])
    )
    assert_equal 1, @events.size
    assert_equal "hi", @events.first[1]["content"]
  end

  # NIP-42: an AUTH challenge is answered with ["AUTH", <signed event>].
  def test_auth_challenge_gets_signed_response
    @pool.auth_with do |challenge, url|
      { "id" => "auth1", "pubkey" => "me", "kind" => 22242, "content" => "",
        "tags" => [["relay", url], ["challenge", challenge]], "sig" => "sig" }
    end
    @pool.connect("wss://r.example")
    @pool.connections["wss://r.example"].fire_message(
      JSON.generate(["AUTH", { "challenge" => "ch9" }])
    )

    frame = JSON.parse(@pool.connections["wss://r.example"].sent.last)
    assert_equal "AUTH", frame[0]
    assert_equal "ch9", frame[1]["tags"].assoc("challenge")[1]
  end

  # "wss://r/" and "wss://r" are the same relay: one connection, one key,
  # and the disconnect callback reports the canonical spelling.
  def test_trailing_slash_variants_share_one_connection
    @pool.connect("wss://r.example/")
    @pool.connect("wss://r.example")
    assert_equal 1, @pool.connections.size
    assert @pool.connections.key?("wss://r.example")

    @pool.connections["wss://r.example"].fire_close
    assert_equal [["wss://r.example", 300]], @dropped
    assert_empty @pool.connections
  end

  def test_disconnect_feeds_penalty_box_hook
    @pool.connect("wss://r.example")
    @pool.connections["wss://r.example"].fire_close
    assert_equal [["wss://r.example", 300]], @dropped
    assert_empty @pool.connections
  end

  # One-shot seeks are finished once the relay reports EOSE: the pool CLOSEs
  # them per relay (fan-out sends the same sub_id to several relays, each one
  # closes independently). Stream subscriptions (subscribe_person) stay open.
  def test_eose_closes_one_shot_seeks_but_keeps_streams_open
    @eose = []
    @pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(url, ev) {},
      on_disconnect: ->(url, penalty) {},
      on_eose: ->(url, sub) { @eose << [url, sub] }
    )
    @pool.connect("wss://a")
    @pool.connect("wss://b")
    @pool.seek_relay_list("wss://a", "seekpk1", "pk1") # fan-out: same id both
    @pool.seek_relay_list("wss://b", "seekpk1", "pk1")
    @pool.seek_profile("wss://a", "profpk1", "pk1")
    @pool.subscribe_person("wss://a", "p_pk1", "pk1") # stream: never closed
    ta = @pool.connections["wss://a"]
    tb = @pool.connections["wss://b"]

    ta.fire_message(JSON.generate(["EOSE", "seekpk1"]))
    assert_equal ["CLOSE", "seekpk1"], JSON.parse(ta.sent.last)
    tb.fire_message(JSON.generate(["EOSE", "seekpk1"]))
    assert_equal ["CLOSE", "seekpk1"], JSON.parse(tb.sent.last) # b closes too

    dup_mark = ta.sent.last # duplicate EOSE: callback still fires, no re-CLOSE
    ta.fire_message(JSON.generate(["EOSE", "seekpk1"]))
    assert_equal dup_mark, ta.sent.last

    ta.fire_message(JSON.generate(["EOSE", "profpk1"]))
    assert_equal ["CLOSE", "profpk1"], JSON.parse(ta.sent.last)

    stream_mark = ta.sent.last
    ta.fire_message(JSON.generate(["EOSE", "p_pk1"]))
    assert_equal stream_mark, ta.sent.last # no CLOSE for stream subs
    assert_equal [["wss://a", "seekpk1"], ["wss://b", "seekpk1"],
                  ["wss://a", "seekpk1"], # duplicate EOSE still notifies
                  ["wss://a", "profpk1"], ["wss://a", "p_pk1"]], @eose
  end

  def test_dropped_relay_discards_its_one_shot_registry
    @pool.connect("wss://a")
    @pool.connections["wss://a"].fire_close
    @pool.connect("wss://a") # reconnected fresh
    ta = @pool.connections["wss://a"]
    ta.fire_message(JSON.generate(["EOSE", "seekpk1"]))
    # registry was reset with the connection: no CLOSE went out
    closes = (ta.sent || []).map { |f| JSON.parse(f)[0] }
    refute_includes closes, "CLOSE"
  end

  def test_publish_sends_event_frame_and_reports_ok
    pub_results = []
    pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
      on_publish_result: ->(url, id, ok, msg) { pub_results << [url, id, ok, msg] }
    )
    pool.connect("wss://r.example")
    event = { id: "e9" * 4, pubkey: "pk", created_at: 1, kind: 1, content: "yo", tags: [], sig: "ab" * 32 }
    assert_equal ["wss://r.example"], pool.publish(event)
    sent = JSON.parse(pool.connections["wss://r.example"].sent.last)
    assert_equal "EVENT", sent[0]
    assert_equal "e9e9e9e9", sent[1]["id"]

    pool.connections["wss://r.example"].fire_message(JSON.generate(["OK", "e9" * 4, true, ""]))
    pool.connections["wss://r.example"].fire_message(JSON.generate(["OK", "e9" * 4, false, "invalid: sig"]))
    assert_equal [["wss://r.example", "e9" * 4, true, ""],
                  ["wss://r.example", "e9" * 4, false, "invalid: sig"]], pub_results
  end

  def test_transmit_to_unknown_relay_is_false
    refute @pool.subscribe_person("wss://nowhere", "s", "pk")
  end

  # Politeness: a relay may throttle concurrent REQs (nos.lol: "too many
  # concurrent REQs"). The pool queues REQs beyond the per-connection cap and
  # starts them FIFO as earlier subs CLOSE.
  def test_req_cap_queues_excess_and_frees_slots_on_close
    pool = Nostrd::RelayPool.new(transport_class: StubTransport,
                                 on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
                                 max_subs_per_conn: 2)
    pool.connect("wss://a")
    pool.subscribe_person("wss://a", "s1", "pk1")
    pool.subscribe_person("wss://a", "s2", "pk2")
    pool.subscribe_person("wss://a", "s3", "pk3") # over cap -> queued
    ids = pool.connections["wss://a"].sent.map { |f| JSON.parse(f)[1] }
    assert_includes ids, "s1"
    assert_includes ids, "s2"
    refute_includes ids, "s3"

    pool.transmit_close("wss://a", "s1") # frees a slot -> s3 starts
    ids = pool.connections["wss://a"].sent.map { |f| JSON.parse(f)[1] }
    assert_includes ids, "s3", "queued REQ starts when a slot frees"
    assert_equal ["s1"], pool.connections["wss://a"].sent
                    .select { |f| JSON.parse(f)[0] == "CLOSE" }.map { |f| JSON.parse(f)[1] }
  end

  # One-shot seeks hold a slot only until their EOSE; the CLOSE frees it and
  # a queued REQ starts without waiting for a manual unsub.
  def test_one_shot_eose_frees_slot_for_queued_req
    pool = Nostrd::RelayPool.new(transport_class: StubTransport,
                                 on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
                                 max_subs_per_conn: 2)
    pool.connect("wss://a")
    pool.seek_relay_list("wss://a", "k1", "pk1") # one-shot, sent
    pool.subscribe_person("wss://a", "s1", "pk1") # stream, sent
    pool.seek_relay_list("wss://a", "k2", "pk2") # queued
    refute pool.connections["wss://a"].sent.any? { |f| JSON.parse(f)[1] == "k2" }

    pool.connections["wss://a"].fire_message(JSON.generate(["EOSE", "k1"]))
    sent = pool.connections["wss://a"].sent.map { |f| JSON.parse(f) }
    assert sent.any? { |m| m[0] == "CLOSE" && m[1] == "k1" }, "one-shot closed on EOSE"
    assert sent.any? { |m| m[0] == "REQ" && m[1] == "k2" }, "queued seek started after EOSE freed a slot"
  end

  def test_cancelled_while_queued_sends_nothing_later
    pool = Nostrd::RelayPool.new(transport_class: StubTransport,
                                 on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
                                 max_subs_per_conn: 1)
    pool.connect("wss://a")
    pool.subscribe_person("wss://a", "s1", "pk1")
    pool.subscribe_person("wss://a", "s2", "pk2") # queued
    pool.transmit_close("wss://a", "s2") # cancel while queued
    pool.transmit_close("wss://a", "s1") # free slot
    refute pool.connections["wss://a"].sent.any? { |f| JSON.parse(f)[1] == "s2" && JSON.parse(f)[0] == "REQ" }
  end

  # The bunker inbox rides a priority slot: it must start immediately even
  # when the politeness cap is full and normal REQs are queued — a queued
  # signer inbox is invisible to NIP-46 clients and looks like a dead bunker.
  def test_bunker_sub_bypasses_cap_and_queue
    pool = Nostrd::RelayPool.new(transport_class: StubTransport,
                                 on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
                                 max_subs_per_conn: 2)
    pool.connect("wss://a")
    pool.subscribe_person("wss://a", "s1", "pk1")
    pool.subscribe_person("wss://a", "s2", "pk2")
    pool.subscribe_person("wss://a", "s3", "pk3") # over cap -> queued
    refute pool.sub_live?("wss://a", "s3"), "normal REQ stays queued over cap"

    pool.subscribe_bunker("wss://a", "bunker", "pk_me")
    assert pool.sub_live?("wss://a", "bunker"), "bunker inbox starts despite full cap"
    assert pool.sub_live?("wss://a", "s1")

    pool.subscribe_bunker("wss://a", "bunker", "pk_me") # tick re-issue: idempotent
    live = pool.instance_variable_get(:@live_subs)["wss://a"]
    assert_equal 1, live.count("bunker"), "no double booking of a live sub"
  end

  # A REQ fired while the relay is down must not count as live (it was never
  # sent). The next ensure_subscribed tick retries it.
  def test_bunker_sub_retries_until_relay_connects
    pool = Nostrd::RelayPool.new(transport_class: StubTransport,
                                 on_event: ->(_, _) {}, on_disconnect: ->(_, _) {})
    pool.subscribe_bunker("wss://a", "bunker", "pk_me") # not connected yet
    refute pool.sub_live?("wss://a", "bunker"), "unsent REQ is not live"

    pool.connect("wss://a")
    refute pool.sub_live?("wss://a", "bunker"), "connecting alone resends nothing"

    pool.subscribe_bunker("wss://a", "bunker", "pk_me") # tick retry
    assert pool.sub_live?("wss://a", "bunker")
    req = JSON.parse(pool.connections["wss://a"].sent.last)
    assert_equal %w[REQ bunker], req.first(2)
    assert_equal [24133], req[2]["kinds"]
    assert_equal ["pk_me"], req[2]["#p"]
  end

  def test_seek_profile_sends_kind0_req
    @pool.connect("wss://r.example")
    assert @pool.seek_profile("wss://r.example", "p1", "pk_alice")
    sent = JSON.parse(@pool.connections["wss://r.example"].sent.last)
    assert_equal ["REQ", "p1", { "authors" => ["pk_alice"], "kinds" => [0], "limit" => 1 }], sent
  end

  # Own kind 3 contact list seek: same one-shot discipline as the other
  # seeks — CLOSED once the relay reports EOSE.
  def test_seek_contact_list_sends_kind3_req_and_closes_on_eose
    @eose = []
    @pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(_, _) {}, on_disconnect: ->(_, _) {},
      on_eose: ->(url, sub) { @eose << [url, sub] }
    )
    @pool.connect("wss://r.example")
    assert @pool.seek_contact_list("wss://r.example", "c1", "me")
    sent = JSON.parse(@pool.connections["wss://r.example"].sent.last)
    assert_equal ["REQ", "c1", { "authors" => ["me"], "kinds" => [3], "limit" => 1 }], sent

    @pool.connections["wss://r.example"].fire_message(JSON.generate(["EOSE", "c1"]))
    closes = @pool.connections["wss://r.example"].sent.map { |f| JSON.parse(f)[0] }
    assert_includes closes, "CLOSE"
    assert_equal [["wss://r.example", "c1"]], @eose
  end

  def test_publish_can_narrow_to_given_urls
    pool = Nostrd::RelayPool.new(
      transport_class: StubTransport,
      on_event: ->(_, _) {}, on_disconnect: ->(_, _) {}
    )
    pool.connect("wss://a")
    pool.connect("wss://b")
    event = { id: "ee" * 4, pubkey: "pk", created_at: 1, kind: 1, content: "x", tags: [], sig: "ab" * 32 }
    assert_equal ["wss://b"], pool.publish(event, urls: ["wss://b"])
    refute Array(pool.connections["wss://a"].sent).any? { |f| JSON.parse(f)[0] == "EVENT" }
    assert_equal "EVENT", JSON.parse(pool.connections["wss://b"].sent.last)[0]
  end
end
