# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_tui/ndjson"
require_relative "../lib/nostr_tui/timeline"
require_relative "../lib/nostr_tui/renderer"
require_relative "../lib/nostr_tui/app"

class TuiTest < Minitest::Test
  def test_ndjson_roundtrip_and_bad_lines
    assert_equal({ "op" => "ping" }, NostrTui::Ndjson.parse(NostrTui::Ndjson.encode(op: "ping")))
    assert_nil NostrTui::Ndjson.parse("{nope")
    assert_nil NostrTui::Ndjson.parse("  \n")
  end

  def test_timeline_sorts_dedupes_and_filters
    tl = NostrTui::Timeline.new
    [{ "id" => "a", "pubkey" => "aaaaaaaa0000", "created_at" => 100, "kind" => 1, "content" => "old" },
     { "id" => "b", "pubkey" => "bbbbbbbb0000", "created_at" => 200, "kind" => 1, "content" => "Ryby は速い" },
     { "id" => "a", "pubkey" => "aaaaaaaa0000", "created_at" => 100, "kind" => 1, "content" => "old dup" },
     { "id" => "r", "pubkey" => "aaaaaaaa0000", "created_at" => 300, "kind" => 10002,
       "content" => "", "tags" => [["r", "wss://x"]] }].each { |h| tl.add_h(h) }

    assert_equal 2, tl.count # relay list (kind 10002) never enters the view
    assert_equal "b", tl.all.first.id
    assert_equal ["b"], tl.filter("ryby").map(&:id)
    assert_equal ["a"], tl.filter("aaaa").map(&:id)
    assert_equal 2, tl.filter(nil).size
  end

  def test_profiles_label_notes_and_extend_search
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "n", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1, "content" => "hi" })
    assert_equal "abababab", tl.find("n").author_short # short pubkey until known

    tl.apply_profiles([{ "pubkey" => "ab" * 16, "display_name" => "Alice",
                         "nip05" => "alice@zaps.lol" }])
    assert_equal "Alice", tl.find("n").author_short
    assert_equal "alice@zaps.lol", tl.find("n").author_handle
    assert_equal "Alice", tl.profile_for("ab" * 16)["display_name"]
    assert_equal ["n"], tl.filter("alice").map(&:id)     # by display name
    assert_equal ["n"], tl.filter("zaps.lol").map(&:id)  # by NIP-05
    assert_equal ["n"], tl.filter("abab").map(&:id)      # still by pubkey
  end

  def test_wrap_widths_paragraphs_and_hard_chop
    r = NostrTui::Renderer.new
    w = ->(text, width) { r.send(:wrap, text, width) }

    assert_equal %w[hello there], w.call("hello there", 10)
    # unspaced CJK counts as 2 cells per char and gets hard-chopped
    lines = w.call("あ" * 7, 6)
    assert_equal ["あああ", "あああ", "あ"], lines
    assert lines.flatten.all? { |l| NostrTui::Renderer.dw(l) <= 6 }
    # blank paragraphs are preserved as separators
    assert_equal ["one", "", "two"], w.call("one\n\ntwo", 20)
    assert_equal [""], w.call("", 20)
    # URLs survive as chop-able tokens
    url = "https://example.com/" + "a" * 30
    assert w.call(url, 20).all? { |l| NostrTui::Renderer.dw(l) <= 20 }
    assert_equal NostrTui::Renderer.dw("あ") * 3, 6
  end

  def test_card_layout_header_body_and_reply_meta
    r = NostrTui::Renderer.new
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "root", "pubkey" => "bb" * 16, "created_at" => 50, "kind" => 1, "content" => "root note" })
    tl.apply_profiles([{ "pubkey" => "bb" * 16, "display_name" => "Bob", "nip05" => "bob@zaps.lol" }])
    tl.add_h({ "id" => "n", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "hello world", "tags" => [["e", "root", "", ""]] })
    tl.apply_profiles([{ "pubkey" => "ab" * 16, "display_name" => "Alice",
                         "nip05" => "alice@zaps.lol" }])
    ev = tl.find("n")

    now = Time.at(100) + 3600
    card = r.send(:card, ev, 60, selected: true, resolve_reply: tl.method(:find), now: now)
    assert_equal 4, card.size # header + body + meta + blank
    header = card[0].text
    assert header.start_with?("▌ ● Alice  @alice@zaps.lol") # SSS avatar + name + handle
    meta = card[2].text
    assert meta.start_with?("  ↩ replying to Bob") # reply context left...
    assert meta.end_with?("1h") # ...relative time right (DS reaction-row slot)
    assert_equal 60, NostrTui::Renderer.dw(meta) # meta row fills the column
    assert_equal "  hello world", card[1].text
    # card_height agrees with the actual card
    assert_equal card.size, r.card_height(ev, 60)

    lines = r.display_lines([ev], first_visible: 0, height: 10, width: 60,
                            selected: 0, resolve_reply: tl.method(:find), now: now)
    assert_equal 4, lines.size
  end

  def test_content_column_capped_and_centered
    assert_equal 84, NostrTui::Renderer.content_width(154)
    assert_equal 35, NostrTui::Renderer.content_left(154)
    assert_equal 84, NostrTui::Renderer.content_width(100) # capped, margins 8/8
    assert_equal 8, NostrTui::Renderer.content_left(100)
    assert_equal 40, NostrTui::Renderer.content_width(40) # narrow: full bleed
    assert_equal 0, NostrTui::Renderer.content_left(40)
  end

  def test_time_label_relative_forms
    now = Time.at(10_000_000)
    f = ->(s) { NostrTui::Renderer.time_label((now - s).to_i, now) }
    assert_equal "now", f.call(0)
    assert_equal "now", f.call(59)
    assert_equal "now", f.call(-120) # clock skew reads as now
    assert_equal "1m", f.call(60)
    assert_equal "59m", f.call(59 * 60)
    assert_equal "1h", f.call(3600)
    assert_equal "23h", f.call(23 * 3600)
    assert_equal "1d", f.call(86_400)
    assert_equal "6d", f.call(6 * 86_400)
    week_ago = now - 7 * 86_400
    assert_equal week_ago.strftime("%m-%d"), NostrTui::Renderer.time_label(week_ago.to_i, now)
    old = now - 400 * 86_400
    assert_equal old.strftime("%Y-%m-%d"), NostrTui::Renderer.time_label(old.to_i, now)
  end

  def test_body_wraps_caps_and_ellipsizes
    r = NostrTui::Renderer.new
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "n", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => ("word " * 60).strip })
    ev = tl.find("n")
    card = r.send(:card, ev, 40, selected: false, resolve_reply: nil)
    # header + 6 capped body lines + "…" + meta row + blank = 10
    assert_equal 10, card.size
    assert_equal "  …", card[-3].text
    assert r.card_height(ev, 40) == card.size
  end

  def test_display_lines_fills_height_and_defers_overflow
    r = NostrTui::Renderer.new
    events = %w[short long].map do |kind|
      NostrTui::Timeline::Event.new(
        kind, "ab" * 16, 100, 1,
        kind == "short" ? "tiny" : ("fill " * 20).strip, []
      )
    end
    # short card = 4 rows (header+body+meta+blank), long card = header+3 body+meta+blank = 6
    lines = r.display_lines(events, first_visible: 0, height: 6, width: 40, selected: 0)
    assert_equal 4, lines.size # 4 + 6 > 6 -> long card deferred, no overflow
    lines = r.display_lines(events, first_visible: 1, height: 6, width: 40, selected: 1)
    assert_equal 6, lines.size
    lines = r.display_lines(events, first_visible: 0, height: 10, width: 40, selected: 0)
    assert_equal 10, lines.size # both fit
  end

  def test_diff_on_text
    r = NostrTui::Renderer.new
    ev = NostrTui::Timeline::Event.new("n", "ab" * 16, 100, 1, "hello", [])
    lines_a = r.display_lines([ev], first_visible: 0, height: 9, width: 40, selected: 0)
    assert_equal :all, r.changed_rows(lines_a)
    lines_same = r.display_lines([ev], first_visible: 0, height: 9, width: 40, selected: 0)
    assert_empty r.changed_rows(lines_same)
    lines_sel = r.display_lines([ev], first_visible: 0, height: 9, width: 40, selected: 0)
    assert_empty r.changed_rows(lines_sel) # same selection, no repaint
  end

  def test_title_bar_tab_bar_and_status_line
    r = NostrTui::Renderer.new
    title = r.title_bar(online: true, width: 60)
    assert title.text.include?("BIRDWATCH")
    assert title.text.end_with?("ONLINE")
    assert r.title_bar(online: false, width: 60).text.end_with?("OFFLINE")

    tabs = r.tab_bar(0, 60)
    assert tabs.text.include?("〈 ホーム 〉") # active tab wrapped in chevrons
    assert %w[フォロー リレー 設定].all? { |t| tabs.text.include?(t) }
    assert r.tab_bar(2, 60).text.include?("〈 リレー 〉")
    assert NostrTui::Renderer.dw(tabs.text) <= 60

    st = r.status_line(count: 100, position: 7, query: "rudy", width: 60)
    assert st.text.include?("▸ 7/100 notes") && st.text.include?("q:rudy")
    assert st.text.end_with?("…") # the active query wins over the key hints
    assert_equal 60, NostrTui::Renderer.dw(st.text)

    full = r.status_line(count: 100, position: 7, query: nil, width: 120)
    assert full.text.include?("q quit") # full hints fit a wide terminal
    assert_equal 120, NostrTui::Renderer.dw(full.text)
    assert r.status_line(count: 100, position: 7, query: nil, width: 100).text.end_with?("…")

    narrow = r.status_line(count: 3, position: 1, query: nil, width: 40)
    assert NostrTui::Renderer.dw(narrow.text) <= 40
    rel = r.status_line(count: 3, position: 1, query: nil, width: 60, noun: "relays")
    assert rel.text.include?("▸ 1/3 relays")
  end

  def test_list_lines_render_selection_and_right_meta
    r = NostrTui::Renderer.new
    items = [{ label: "Alice", sub: "alice@zaps.lol", right: "ab12…45" },
             { label: "wss://relay.example.com", right: "connected" }]
    lines = r.list_lines(items, first_visible: 0, height: 5, width: 60, selected: 0)
    assert_equal 2, lines.size
    assert lines[0].text.start_with?("▌ ● Alice  alice@zaps.lol")
    assert lines[0].text.end_with?("ab12…45")
    assert_equal 60, NostrTui::Renderer.dw(lines[0].text) # padded to column width
    assert lines[1].text.start_with?("  ● wss://")
    assert lines[1].text.end_with?("connected")
    sel1 = r.list_lines(items, first_visible: 0, height: 5, width: 60, selected: 1)
    assert sel1[1].text.start_with?("▌ ● wss://") # bar follows selection
  end

  def test_app_drains_events_profiles_and_clamps_selection
    tl = NostrTui::Timeline.new
    app = NostrTui::App.new(timeline: tl)
    app.drain({ "ev" => "event", "event" => { "id" => "x", "pubkey" => "cc" * 8, "created_at" => 1,
                                              "kind" => 1, "content" => "hi" } })
    app.drain({ "ev" => "eod", "sub" => "tl" })
    assert_equal 1, app.visible_events.size
    app.move(99)
    assert_equal app.visible_events.size - 1, app.visible_events.rindex(app.selected_event)

    app.drain({ "ev" => "profiles", "profiles" => [{ "pubkey" => "cc" * 8, "name" => "Carol" }] })
    assert_equal "Carol", app.visible_events.first.author_short
  end

  def test_app_info_frame_keeps_my_profile_and_locked
    tl = NostrTui::Timeline.new
    app = NostrTui::App.new(timeline: tl)
    app.drain({ "ev" => "info", "follows" => [], "relays" => [],
                "my_profile" => { "name" => "ロクヨウ", "display_name" => "塩ヶ浜しお" },
                "locked" => true })
    prof = app.instance_variable_get(:@info)
    assert_equal "ロクヨウ", prof.dig("my_profile", "name")
    assert_equal true, prof["locked"]
    labels = app.send(:settings_items).map { |r| r[:label] }
    assert_includes labels, "unlock" # locked → u row visible
    row = app.send(:settings_items).find { |r| r[:label] == "profile" }
    assert_equal "塩ヶ浜しお", row[:sub] # no more "not set"
  end

  def test_app_info_frame_carries_profiles_for_follows_tab
    tl = NostrTui::Timeline.new
    app = NostrTui::App.new(timeline: tl)
    app.drain({ "ev" => "info", "follows" => ["aa" * 32], "relays" => [],
                "profiles" => [{ "pubkey" => "aa" * 32, "name" => "Alice" }] })
    app.set_tab(1)
    assert_equal "Alice", app.send(:list_items).first[:label] # served with info
  end

  def test_app_info_frames_and_tab_switching
    tl = NostrTui::Timeline.new
    tl.apply_profiles([{ "pubkey" => "aa" * 32, "display_name" => "Alice",
                         "nip05" => "a@zaps.lol" }])
    app = NostrTui::App.new(timeline: tl)
    app.drain({ "ev" => "info", "follows" => ["aa" * 32],
                "relays" => [{ "url" => "wss://r.example", "state" => "connected" }] })
    app.set_tab(1)
    assert_equal 1, app.instance_variable_get(:@tab)
    follows = app.send(:list_items)
    assert_equal "Alice", follows.first[:label] # profile-resolved
    assert_equal "a@zaps.lol", follows.first[:sub]
    app.set_tab(2)
    assert_equal "wss://r.example", app.send(:list_items).first[:label]
    app.set_tab(3)
    assert app.send(:list_items).first[:label].include?("birdwatch")
    app.set_tab(-1) # wraps to the last tab
    assert_equal 3, app.instance_variable_get(:@tab)
    app.set_tab(0)
    assert_nil app.selected_event # home is empty here
    assert_equal 0, app.instance_variable_get(:@selected)
  end

  # Regression (bug 18): run() used to drop the client on the floor — the
  # title bar stayed OFFLINE even while online. attach() is the seam run()
  # and tests share; the ONLINE/OFFLINE badge comes from client.connected?.
  def test_app_attach_wires_client_into_status
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    client = Object.new
    def client.path = "/tmp/nostrd-live.sock"
    def client.connected? = true

    r = app.instance_variable_get(:@renderer)
    assert r.title_bar(online: false, width: 100).text.include?("OFFLINE")
    app.attach(client)
    # paint() passes client.connected? straight into the title bar
    assert r.title_bar(online: app.instance_variable_get(:@client)&.connected? || false,
                       width: 100).text.include?("ONLINE")
  end

  # Regression (bug 20): open_link/yank call Shellwords.escape, but app.rb
  # never required "shellwords" — every `o` press died with a NameError
  # before xdg-open ran (tests never caught it: minitest's own requires load
  # shellwords transitively, the real TUI doesn't).
  def test_open_link_hands_the_full_url_to_the_browser
    long = "https://share.yabu.me/a19caaa8404721584746fb0e174cf971a94e0f51baaf4c4e8c6e54fa88985eaf/d547b6f3f67bcf1f50ce8904e53033badbef84c2b462928e2e0e6475172c6c62.webp"
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "e1", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "画像\n#{long}。" })
    app = NostrTui::App.new(timeline: tl)
    cmds = []
    app.define_singleton_method(:system) { |c| cmds << c; true }

    app.send(:open_link)

    # full raw URL reaches xdg-open; the display wraps it, the shell never sees that
    # child stdio detached from the TTY (its chatter would damage the screen)
    assert_equal "xdg-open #{long} >/dev/null 2>&1 </dev/null", cmds.first
  end

  def test_timeline_indexes_kind7_reactions_out_of_view
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "note", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "like me" })
    [{ "id" => "r1", "pubkey" => "cd" * 16, "kind" => 7, "content" => "+",
       "tags" => [["e", "note"], ["p", "ab" * 16]] },
     { "id" => "r2", "pubkey" => "ef" * 16, "kind" => 7, "content" => "+",
       "tags" => [["e", "note"]] },
     { "id" => "r3", "pubkey" => "cd" * 16, "kind" => 7, "content" => "👎",
       "tags" => [["e", "note"]] }].each { |h| tl.add_h(h) }

    assert_equal 1, tl.count # reactions never enter the note view
    assert_equal 2, tl.reaction_count("note") # indexed per author pubkey
    assert_equal 0, tl.reaction_count("missing")
    assert_equal true, tl.liked_by_me?("note", "cd" * 16) # r1 author
    assert_equal true, tl.liked_by_me?("note", "ef" * 16) # r2 author
    assert_equal false, tl.liked_by_me?("note", "12" * 16) # never reacted
    assert_equal false, tl.liked_by_me?("note", nil) # own pubkey unknown yet
  end

  def test_like_sends_action_for_selected_note
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "e1", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "like me" })
    app = NostrTui::App.new(timeline: tl)
    sent = []
    client = Object.new
    client.define_singleton_method(:like) { |id:, pubkey:| sent << [id, pubkey]; true }

    sent.clear
    app.send(:like, client)

    assert_equal ["e1", "ab" * 16], sent.first
    assert_equal "liked +1", app.instance_variable_get(:@flash)
  end

  # Relay tab rows are gossip-style: five switch letters (R I W O D, "-" when
  # off) mid-row, live state right, state-colored dot (filled = connected,
  # hollow = configured but down).
  def test_relay_tab_rows_are_gossip_style
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@info, {
                                "relays" => [
                                  { "url" => "wss://nos.lol", "state" => "connected",
                                    "read" => true, "inbox" => true, "write" => true,
                                    "outbox" => false, "discover" => false },
                                  { "url" => "wss://nostr.wine", "state" => "offline",
                                    "read" => false, "inbox" => false, "write" => true,
                                    "outbox" => true, "discover" => true }
                                ]
                              })

    rows = app.send(:relays_items)
    assert_equal "R I W - - -", rows[0][:sub]
    assert_equal "- - W O D -", rows[1][:sub]
    assert_equal true, rows[0][:up]
    assert_equal false, rows[1][:up]
    assert_equal "connected", rows[0][:right]

    r = NostrTui::Renderer.new
    up = r.send(:list_row, rows[0], 60, selected: false)
    down = r.send(:list_row, rows[1], 60, selected: false)
    assert up.text.include?("wss://nos.lol") && up.text.include?("R I")
    assert down.text.include?("○ "), "offline relay renders a hollow dot"
    assert !up.text.include?("○ ")
  end

  # R/I/W/O/D toggle the selected relay's switches; inbox forces read on
  # (gossip semantics); A advertises. Non-relay tabs refuse.
  def test_relay_switch_toggles_and_advertise
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@info, {
                                "relays" => [{ "url" => "wss://nos.lol", "state" => "connected",
                                               "read" => true, "inbox" => false, "write" => true,
                                               "outbox" => false, "discover" => false }]
                              })
    app.instance_variable_set(:@tab, 2)
    sent = []
    client = Object.new
    client.define_singleton_method(:relay_flags) do |url, **f|
      sent << [url, f]
      true
    end
    client.define_singleton_method(:advertise_relays) { sent << :adv; true }
    client.define_singleton_method(:relay_remove) { |url| sent << [:rm, url]; true }

    # inbox on -> read stays on, message flashes
    app.instance_variable_set(:@selected, 0)
    app.send(:relay_command, :relay_inbox, client)
    assert_equal ["wss://nos.lol", { read: true, inbox: true, write: true,
                                     outbox: false, discover: false, search: false }], sent.first
    assert_includes app.instance_variable_get(:@flash), "inbox on"

    # discover toggles (was off -> on)
    app.send(:relay_command, :relay_discover, client)
    assert_equal true, sent.last[1][:discover]

    # advertise sends its own op
    app.send(:relay_command, :relay_advertise, client)
    assert_equal :adv, sent.last
    assert_includes app.instance_variable_get(:@flash), "advertised"

    # remove sends relay_remove for the selected relay
    app.send(:relay_command, :relay_remove, client)
    assert_equal [:rm, "wss://nos.lol"], sent.last

    # add normalizes scheme-less input (ask_line stubbed via io)
    app.define_singleton_method(:ask_line) { |_p| "wss://pay.relay" }
    app.send(:relay_command, :relay_add, client)
    assert_equal "wss://pay.relay", sent.last[0]
    assert_equal true, sent.last[1][:read]

    # wrong tab refuses
    app.instance_variable_set(:@tab, 0)
    app.send(:relay_command, :relay_read, client)
    assert_equal "relays tab only", app.instance_variable_get(:@flash)
  end

  def test_card_shows_reaction_count_and_own_like_marker
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "note", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "like me" })
    tl.add_h({ "id" => "r1", "pubkey" => "cd" * 16, "kind" => 7, "content" => "+",
               "tags" => [["e", "note"]] })
    r = NostrTui::Renderer.new
    reactions = tl.method(:reaction_count)
    liked = ->(id) { tl.liked_by_me?(id, "cd" * 16) }

    plain = r.send(:card, tl.find("note"), 60, selected: false, resolve_reply: nil,
                   reactions: reactions, liked: ->(_) { false })
    # Other people's reactions never render — only my own 👍 shows.
    assert_empty plain.filter { |l| l.text.include?("👍") }

    mine = r.send(:card, tl.find("note"), 60, selected: false, resolve_reply: nil,
                  reactions: reactions, liked: liked)
    meta_mine = mine.find { |l| l.text.include?("👍") }
    assert meta_mine.text.include?("✓"), "own like must carry the ✓ marker"
  end

  def test_like_without_selection_flashes_hint
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.send(:like, nil)
    assert_equal "no note selected", app.instance_variable_get(:@flash)
  end

  # Follows tab: `o` opens the profile on npub.world (hex pubkey URL).
  def test_open_link_on_follows_tab_opens_npub_world
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@info, { "follows" => ["ab" * 16] })
    app.instance_variable_set(:@tab, 1)
    app.instance_variable_set(:@selected, 0)
    cmds = []
    app.define_singleton_method(:system) { |c| cmds << c; true }

    app.send(:open_link)

    assert_equal 1, cmds.size
    assert_includes cmds.first, "https://npub.world/#{'ab' * 16}"
  end

  def test_open_link_without_selection_is_a_noop
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    cmds = []
    app.define_singleton_method(:system) { |c| cmds << c; true }

    assert_nil app.send(:open_link)
    assert_empty cmds
  end

  def test_links_trim_trailing_prose_punctuation
    tl = NostrTui::Timeline.new
    tl.add_h({ "id" => "e2", "pubkey" => "ab" * 16, "created_at" => 100, "kind" => 1,
               "content" => "見て https://example.com/i.png! 次は https://example.com/b.jpg。" })
    assert_equal ["https://example.com/i.png", "https://example.com/b.jpg"],
                 tl.links(tl.all.first)
  end

  # Bug 21: run() never enabled stdscr.keypad, so arrow keys arrived as raw
  # bytes — the leading ESC (27) matched the :quit mapping and the TUI exited
  # instead of moving tabs. The keypad line is the fix; translate() maps the
  # decoded keypad constants onto the same :tab_prev/:tab_next tokens as h/l.
  def test_translate_maps_arrow_keys_to_tab_movement
    require "curses"
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    # LEFT/RIGHT must fold onto the KEYMAP *tokens* "h"/"l" — KEYMAP maps
    # token -> action, so returning the action itself from translate() is a
    # miss (bug 21b: arrows stopped quitting but still didn't move tabs).
    assert_equal "h", app.send(:translate, Curses::Key::LEFT)
    assert_equal "l", app.send(:translate, Curses::Key::RIGHT)
    assert_equal "j", app.send(:translate, Curses::Key::DOWN)
    assert_equal "k", app.send(:translate, Curses::Key::UP)
  end

  def test_run_enables_keypad_and_lone_esc_still_quits
    require "curses"
    real = %w[init_screen start_color use_default_colors colors init_pair
              curs_set noecho stdscr getch close_screen]
             .filter_map { |m| Curses.respond_to?(m) ? [m, Curses.method(m)] : nil }.to_h
    keypad_on = nil
    stdscr = Object.new
    stdscr.define_singleton_method(:keypad=) { |v| keypad_on = v }
    stdscr.define_singleton_method(:timeout=) { |_| }
    Curses.define_singleton_method(:init_screen) { nil }
    Curses.define_singleton_method(:start_color) { nil }
    Curses.define_singleton_method(:use_default_colors) { nil }
    Curses.define_singleton_method(:colors) { 256 }
    Curses.define_singleton_method(:init_pair) { |*| nil }
    Curses.define_singleton_method(:curs_set) { |*| nil }
    Curses.define_singleton_method(:noecho) { nil }
    Curses.define_singleton_method(:stdscr) { stdscr }
    Curses.define_singleton_method(:getch) { 27 } # lone ESC -> :quit on the first pass
    Curses.define_singleton_method(:close_screen) { nil }

    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.define_singleton_method(:drain_socket) { |_| nil }
    app.define_singleton_method(:paint) { nil }
    app.run

    assert_equal true, keypad_on, "arrows must be decoded: stdscr.keypad must be on"
    # run returned (ESC quit) rather than hanging — the loop iterated once
  ensure
    real.each { |m, meth| Curses.define_singleton_method(m) { |*a, &b| meth.call(*a, &b) } }
  end

  def test_app_ensure_visible_scrolls_varheight_cards
    r = NostrTui::Renderer.new
    tl = NostrTui::Timeline.new
    12.times do |i|
      tl.add_h({ "id" => "e#{i}", "pubkey" => "ab" * 16, "created_at" => 1000 - i, "kind" => 1,
                 "content" => i.even? ? "tiny #{i}" : ("fill " * 25).strip })
    end
    app = NostrTui::App.new(timeline: tl, renderer: r)
    events = app.visible_events
    app.move(5) # headless: follow_selection skips screen math without a screen
    app.send(:ensure_visible, events, 8, 40)
    first = app.instance_variable_get(:@first_visible)
    assert first <= 5
    used = (first..5).sum { |i| r.card_height(events[i], 40) }
    assert used <= 8 # selected card fully on screen
    if first.positive?
      tighter = (first - 1..5).sum { |i| r.card_height(events[i], 40) }
      assert tighter > 8 # and it scrolled the minimum amount
    end

    app.jump_top
    app.send(:ensure_visible, events, 8, 40)
    assert_equal 0, app.instance_variable_get(:@first_visible)
  end

  # Replies open with a "RE: <author>" header; the editor must land the
  # cursor on line 2 so typing starts immediately (no manual j first).
  def test_editor_command_positions_cursor_on_line2_for_replies
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    old = ENV["EDITOR"]
    begin
      ENV["EDITOR"] = "vim"
      assert_equal 'vim +"2" +startinsert /tmp/buf.md',
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      ENV["EDITOR"] = "nano"
      assert_equal "nano +2 /tmp/buf.md",
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      # helix takes +N ("open the first file at line N")
      ENV["EDITOR"] = "hx"
      assert_equal "hx +2 /tmp/buf.md",
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      # omarchy wraps the real editor; --inline forwards every following arg,
      # so the wrapper must resolve to its default (helix on this machine).
      ENV["EDITOR"] = "omarchy-launch-editor --inline"
      app.define_singleton_method(:omarchy_inline_editor) { "helix" }
      assert_equal "omarchy-launch-editor --inline +2 /tmp/buf.md",
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      app.define_singleton_method(:omarchy_inline_editor) { "nvim" }
      assert_equal 'omarchy-launch-editor --inline +"2" +startinsert /tmp/buf.md',
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      app.define_singleton_method(:omarchy_inline_editor) { "code" } # GUI editor: no flags
      assert_equal "omarchy-launch-editor --inline /tmp/buf.md",
                   app.send(:editor_command, "/tmp/buf.md", :reply)
      ENV["EDITOR"] = "code" # unknown direct editor: buffer opens plain
      assert_equal "code /tmp/buf.md", app.send(:editor_command, "/tmp/buf.md", :reply)
      # Profile edit: vim/nvim start typing on line 1 (no line-2 positioning).
      ENV["EDITOR"] = "vim"
      assert_equal "vim +startinsert /tmp/buf.md",
                   app.send(:editor_command, "/tmp/buf.md", :insert)
      ENV["EDITOR"] = "hx"
      assert_equal "hx /tmp/buf.md", app.send(:editor_command, "/tmp/buf.md", :insert)
      # New post (no RE header): no positioning flags even in vim.
      ENV["EDITOR"] = "vim"
      assert_equal "vim /tmp/buf.md", app.send(:editor_command, "/tmp/buf.md", nil)
    ensure
      ENV["EDITOR"] = old
    end
  end

  # The relays tab must show its own editing keys (R/I/W/O/D/S, a/x/A) in
  # the status bar — otherwise the switches are undiscoverable.
  def test_status_line_hints_are_per_tab
    r = NostrTui::Renderer.new
    assert r.status_line(count: 1, position: 1, query: nil, width: 120).text.include?("r reply")

    relays = r.status_line(count: 2, position: 1, query: nil, width: 120,
                           noun: "relays", hints: NostrTui::Renderer::HINTS[2])
    assert relays.text.include?("R/I/W/O/D/S switch")
    assert relays.text.include?("a add") && relays.text.include?("A advertise")

    follows = r.status_line(count: 2, position: 1, query: nil, width: 120,
                            noun: "follows", hints: NostrTui::Renderer::HINTS[1])
    assert follows.text.include?("o profile")
    refute follows.text.include?("r reply")
    assert NostrTui::Renderer.dw(relays.text) <= 120
  end

  # Settings tab: three rows only — brand, profile (e), nostr connect (o).
  def test_settings_tab_rows
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@info, { "me" => "ab" * 16,
                                        "my_profile" => { "name" => "ロクヨウ" } })
    rows = app.send(:settings_items).map { |i| i[:label] }
    assert_equal ["birdwatch 0.1", "profile", "nostr connect", "logout", "import key"], rows
    # locked daemon: an unlock row appears between connect and logout
    app.instance_variable_set(:@info, { "locked" => true })
    assert_equal "unlock", app.send(:settings_items)[3][:label]
    app.instance_variable_set(:@info, { "me" => "ab" * 16,
                                        "my_profile" => { "name" => "ロクヨウ" } })
    assert_equal "ロクヨウ", app.send(:settings_items)[1][:sub]
  end

  # Settings tab: o on the "nostr connect" row asks the daemon for its
  # persistent bunker URI (the daemon is the signer; the phone pairs as the
  # client). The QR itself is a modal/broker page; here we assert the request
  # goes out and the row-keyed routing picks the connect row only.
  def test_open_on_settings_tab_requests_bunker_uri
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@tab, 3)
    sent = []
    client = Object.new
    client.define_singleton_method(:bunker_secret) { sent << :bsec }
    app.instance_variable_set(:@selected, 2) # "nostr connect" row
    app.send(:settings_action, "o", client)
    assert_equal [:bsec], sent

    # offline: no client -> flash, no pending request left dangling
    app.send(:settings_action, "o", nil)
    assert_equal "daemon に接続できません", app.instance_variable_get(:@flash)
    assert_equal false, app.instance_variable_get(:@connect_pending)
  end

  def test_profile_edit_sends_update_and_flashes
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    sent = []
    client = Object.new
    client.define_singleton_method(:update_profile) { |json| sent << json }
    app.define_singleton_method(:profile_buffer) { '{"name":"ロクヨウ"}' }
    app.send(:profile_edit, client)
    assert_equal ['{"name":"ロクヨウ"}'], sent
    assert_equal "profile update sent (kind 0)", app.instance_variable_get(:@flash)
  end

  # Settings actions are ROW-keyed: e/o/s/u/i act on the selected row only.
  def test_settings_actions_are_row_keyed
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@tab, 3)
    app.instance_variable_set(:@selected, 1) # profile row
    edited = []
    app.define_singleton_method(:profile_edit) { |c| edited << c }
    app.send(:settings_action, "e", :client)
    assert_equal [:client], edited
    app.instance_variable_set(:@selected, 0) # birdwatch row: o opens GitHub
    opened = []
    app.define_singleton_method(:open_external) { |cmd| opened << cmd }
    app.send(:settings_action, "o", :client)
    assert_equal 1, opened.size
    assert_includes opened.first, Shellwords.escape(NostrTui::App::GITHUB_URL)
    assert_equal :unlock, NostrTui::App::KEYMAP["u"] # u maps to the unlock row action
  end

  def test_unlock_and_import_flows
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    got = []
    client = Object.new
    client.define_singleton_method(:unlock) { |p| got << [:unlock, p] }
    client.define_singleton_method(:import_key) { |k, p| got << [:import, k, p] }
    prompts = ["s3cret", "nsec1abc", "newpass"]
    app.define_singleton_method(:ask_line) { |_p, mask: false| prompts.shift }
    app.send(:unlock_session, client)
    app.send(:import_key, client)
    assert_equal [[:unlock, "s3cret"], [:import, "nsec1abc", "newpass"]], got
  end

  def test_signout_locks_signer_and_flashes
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    sent = []
    client = Object.new
    client.define_singleton_method(:signout) { sent << :lock }
    app.send(:signout, client)
    assert_equal [:lock], sent
    assert_equal "signed out — signer locked", app.instance_variable_get(:@flash)
    app.send(:signout, nil)
    assert_equal "signout failed (offline?)", app.instance_variable_get(:@flash)
  end

  def test_profile_edit_rejects_invalid_json
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.define_singleton_method(:profile_buffer) { '{oops' }
    app.send(:profile_edit, nil)
    assert_equal "invalid profile JSON — not saved", app.instance_variable_get(:@flash)
  end

  # --- NIP-46 connect QR -----------------------------------------------------

  def test_qr_block_lines_are_square_half_blocks_with_quiet_zone
    uri = "bunker://#{'ab' * 32}?relay=wss%3A%2F%2Fnos.lol&secret=#{'0' * 32}"
    lines = NostrTui::App.qr_block_lines(uri)

    assert lines.size >= 15 # minimum QR (21 modules) + 8 quiet -> 15 rows
    widths = lines.map(&:length)
    assert_equal 1, widths.uniq.size                 # every line the same width
    assert_equal (widths.first + 1) / 2, lines.size  # cells == 2 module rows
    assert lines.join.chars.all? { |c| "█▀▄ ".include?(c) }
    assert_equal " " * widths.first, lines.first     # quiet zone stays blank
    assert_equal " " * widths.first, lines.last
  end

  def test_drain_result_records_bunker_uri_and_fires_modal_when_live
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.drain({ "ev" => "result", "id" => "bsec_1", "data" => { "uri" => "bunker://abc" } })
    assert_equal "bunker://abc", app.instance_variable_get(:@bunker_uri)
    assert_equal false, app.instance_variable_get(:@connect_pending)

    shown = []
    app.define_singleton_method(:show_connect_modal) { shown << @bunker_uri }
    app.instance_variable_set(:@screen_live, true)
    app.drain({ "ev" => "result", "id" => "bsec_2", "data" => { "uri" => "bunker://def" } })
    assert_equal ["bunker://def"], shown # modal opens once curses owns the screen
  end

  def test_drain_bsec_ack_failure_clears_pending_and_flashes
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    app.instance_variable_set(:@connect_pending, true)
    app.drain({ "ev" => "ack", "id" => "bsec_1", "ok" => false, "error" => "bunker unavailable" })
    assert_equal false, app.instance_variable_get(:@connect_pending)
    assert_includes app.instance_variable_get(:@flash).to_s, "bunker unavailable"
  end

  def test_request_connect_qr_sends_op_and_handles_offline
    app = NostrTui::App.new(timeline: NostrTui::Timeline.new)
    sent = []
    client = Object.new
    client.define_singleton_method(:bunker_secret) { sent << :bsec }
    app.send(:request_connect_qr, client)
    assert_equal [:bsec], sent
    assert app.instance_variable_get(:@connect_pending)

    app.send(:request_connect_qr, nil)
    assert_equal false, app.instance_variable_get(:@connect_pending)
    assert_equal "daemon に接続できません", app.instance_variable_get(:@flash)
  end
end
