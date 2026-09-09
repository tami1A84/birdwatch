# frozen_string_literal: true

require "shellwords"
require "cgi"

module NostrTui
  # The curses shell. All logic lives elsewhere; this only paints and reads keys.
  # If curses is missing, every pure layer is still testable headless.
  class App
    require_relative "renderer"
    require_relative "timeline"
    KEYMAP = {
      "j" => :down, "k" => :up, "g" => :top, "G" => :bottom,
      "h" => :tab_prev, "l" => :tab_next, # SSS tab strip
      "1" => :tab1, "2" => :tab2, "3" => :tab3, "4" => :tab4,
      :pgup => :page_up, :pgdn => :page_down,
      "/" => :search, "r" => :reply, "n" => :compose,
      "m" => :chat_send, "\r" => :chat_open, # chat tab: send / open-close thread
      "L" => :like, # NIP-25 reaction on the selected note
      "R" => :relay_read, "I" => :relay_inbox, "W" => :relay_write,
      "O" => :relay_outbox, "D" => :relay_discover, "S" => :relay_search,
      "a" => :relay_add, "x" => :relay_remove, "A" => :relay_advertise,
      "y" => :yank, "o" => :open, "e" => :profile_edit, "s" => :signout,
      "i" => :import_key, "u" => :unlock,
      "q" => :quit, 27 => :quit # ESC
    }.freeze
    NOUNS = %w[notes follows relays dms items].freeze
    GITHUB_URL = "https://github.com/tami1A84/birdwatch" # settings: birdwatch row + o

    # curses color pairs (cyan accent on the default bg; every pair — PANEL
    # included — uses -1, so the feed column matches the terminal background)
    ACCENT = 1
    DIM = 2
    PANEL = 3
    ACCENT_PANEL = 4
    DIM_PANEL = 5
    QR_PAIR = 6 # NIP-46 connect QR: black modules on white background

    def initialize(timeline:, renderer: Renderer.new, io: $stdout)
      @timeline = timeline
      @renderer = renderer
      @io = io
      @client = nil
      @query = nil
      @tab = 0
      @info = {}
      @selected = 0
      @selected_id = nil
      @first_visible = 0
      @expanded = nil
      @modal = nil        # NIP-46 connect QR overlay (hash: uri/qr/width)
      @connect_pending = false
      @bunker_uri = nil
      @chat_partner = nil # nil = conversation list; pubkey = open thread
      @chat_convs = []    # [{pubkey, last, count}] from the dms channel
      @chat_msgs = []     # open thread's kind-14 rumors, oldest first
      @chat_fetch = nil   # sub id of the in-flight dms fetch
      @dm_seq = 0
      @reconnect_at = nil # throttle for the dead-socket redial loop
      @screen_live = false # run() flips this once curses owns a real screen
    end

    # Headless drain: feeds socket messages into the timeline without curses.
    # The curses loop lives in App#run (needs a real TTY).
    def drain(message)
      case message["ev"]
      when "event"
        # dms-channel event frames carry the fetch's sub id; route them to
        # the open thread instead of the home timeline (kind-14 rumors are
        # DM content, not feed notes).
        if message["sub"].to_s.start_with?("dms_") && message["sub"] == @chat_fetch
          @chat_msgs << message["event"] if @chat_partner && message["event"]
          @chat_msgs.sort_by! { |r| r["created_at"].to_i }
        else
          @timeline.add_h(message["event"])
        end
      when "conversations"
        @chat_convs = message["conversations"] || [] if message["sub"] == @chat_fetch
      when "profiles" then @timeline.apply_profiles(message["profiles"] || [])
      when "info"
        @info = { "follows" => message["follows"] || [],
                  "me" => message["me"],
                  "my_profile" => message["my_profile"],
                  "locked" => message["locked"] || false,
                  "relays" => message["relays"] || [] }
        # The follows tab labels people through the timeline's profile cache;
        # the daemon serves stored metadata with the list so names render
        # right after a restart instead of waiting for live kind-0 traffic.
        @timeline.apply_profiles(message["profiles"] || [])
      when "eod", "ack"
        # bunker_secret failures arrive as ack(ok:false) with the bsec_ id.
        if message["ev"] == "ack"
          if !message["ok"] && message["id"].to_s.start_with?("bsec_")
            @connect_pending = false
            flash("bunker URI: #{message['error']}")
          elsif message["id"].to_s.start_with?("dmsend_")
            # Our rumor is stored daemon-side; pull the refreshed thread.
            message["ok"] ? refresh_chat : flash("send failed: #{message['error']}")
          end
        end
        true
      when "result"
        # Daemon answered a request (currently only bunker_secret). The URI
        # opens the connect QR modal; headless runs just record it.
        if message["id"].to_s.start_with?("bsec_")
          @connect_pending = false
          @bunker_uri = message.dig("data", "uri").to_s
          show_connect_modal if @screen_live
        end
        true
      when "error" then warn "daemon: #{message['code']}"
      end
      clamp_selection
    end

    def visible_events = @timeline.filter(@query)

    def selected_event = @tab.zero? ? visible_events[@selected] : nil

    def view_size = @tab.zero? ? visible_events.size : list_items.size

    def move(delta)
      @selected = (@selected + delta).clamp(0, [view_size - 1, 0].max)
      remember_selection if @tab.zero?
      follow_selection
    end

    def jump_top
      @selected = 0
      remember_selection
      follow_selection
    end

    def jump_bottom = move(view_size)

    def search(query)
      @query = query.to_s.empty? ? nil : query
      @selected = 0
      @first_visible = 0
      remember_selection
    end

    # SSS tab switch: resets the viewport, re-asks the daemon for follows/relays.
    def set_tab(index)
      @tab = index % Renderer::TABS.size
      @selected = 0
      @first_visible = 0
      @selected_id = nil
      @client&.request_info
      refresh_chat if @tab == 3 # chat: re-pull list or the open thread
    end

    # --- curses (requires a TTY and the curses gem) ---

    # The curses shell binds its client here so paint()/settings_items() see it;
    # headless tests call attach directly (run() does it on entry).
    def attach(client) = @client = client

    def run(client: nil)
      attach(client)
      require "curses"
      ENV["ESCDELAY"] ||= "25" # lone ESC stays a snappy quit; escape sequences still decode
      Curses.init_screen
      @screen_live = true
      Curses.start_color
      Curses.use_default_colors
      Curses.stdscr.keypad = true # decode arrows/PgUp/PgDn — without it ← arrives as raw ESC bytes and hits the :quit mapping
      cyan = Curses.colors >= 256 ? 81 : Curses::COLOR_CYAN # accent
      gray = Curses.colors >= 256 ? 244 : Curses::COLOR_BLACK
      Curses.init_pair(ACCENT, cyan, -1)
      Curses.init_pair(DIM, gray, -1)
      # Every pair paints on the terminal's default background (-1). The feed
      # column keeps its own pair names so the paint path is untouched, but it
      # no longer carries a hard-coded dark panel — no black block in the
      # middle regardless of the terminal theme.
      Curses.init_pair(PANEL, -1, -1)
      Curses.init_pair(ACCENT_PANEL, cyan, -1)
      Curses.init_pair(DIM_PANEL, gray, -1)
      Curses.init_pair(QR_PAIR, Curses::COLOR_BLACK, Curses::COLOR_WHITE)
      Curses.curs_set(0)
      Curses.noecho
      # Multibyte input (Japanese search): without a locale/encoding hint,
      # getch returns single bytes for UTF-8 and ask_line drops them.
      Curses.set_encoding("UTF-8") if Curses.respond_to?(:set_encoding)
      Curses.stdscr.timeout = 250 # getch yields nil between keystrokes -> live feed repaints

      loop do
        drain_socket(client)
        if @modal
          paint_modal
          Curses.stdscr.timeout = -1 # block: the modal stays until a keypress
          Curses.getch # any key closes; ESC here must not quit the app
          Curses.stdscr.timeout = 250
          @modal = nil
          @renderer.reset # next paint() redraws every row the QR covered
          next
        end
        paint
        raw = Curses.getch
        action = KEYMAP[translate(raw)] or next
        case action
        when :quit
          # ESC with an active filter clears the search first (gossip-like
          # progressive exit); a second ESC / q quits.
          if raw == 27 && @query && @tab.zero?
            search("")
          else
            break
          end
        when :down then move(1)
        when :up then move(-1)
        when :top then jump_top
        when :bottom then jump_bottom
        when :tab_prev then set_tab(@tab - 1)
        when :tab_next then set_tab(@tab + 1)
        when :tab1 then set_tab(0)
        when :tab2 then set_tab(1)
        when :tab3 then set_tab(2)
        when :tab4 then set_tab(3)
        when :tab5 then set_tab(4)
        when :page_up then move(-page_step)
        when :page_down then move(page_step)
        when :yank then yank
        when :open then @tab == 4 ? settings_action('o', client) : open_link
        when :search
          if @tab.zero?
            q = ask_line("search: ")
            search(q) unless q.nil? # ESC = cancel (keep filter); empty Enter = clear
          end
        when :compose then compose(client, reply_to: nil)
        when :reply then compose(client, reply_to: selected_event)
        when :like then like(client)
        when :profile_edit then settings_action("e", client)
        when :signout then settings_action("s", client)
        when :import_key then settings_action("i", client)
        when :unlock then settings_action("u", client)
        when :relay_read, :relay_inbox, :relay_write, :relay_outbox,
             :relay_discover, :relay_search, :relay_add, :relay_remove,
             :relay_advertise
          relay_command(action, client)
        when :chat_open then chat_enter(client)
        when :chat_send then chat_compose(client)
        end
      end
    ensure
      Curses.close_screen if defined?(Curses)
      @screen_live = false
    end

    private

    # curses keypad constants -> KEYMAP tokens (arrows work alongside hjkl)
    def translate(key)
      case key
      when Curses::Key::DOWN then "j"
      when Curses::Key::UP then "k"
      when Curses::Key::LEFT then "h"   # arrows fold into the same tokens as h/l
      when Curses::Key::RIGHT then "l"
      when Curses::Key::PPAGE then :pgup
      when Curses::Key::NPAGE then :pgdn
      else key
      end
    end

    def page_step
      return 1 unless @screen_live # headless: no screen geometry

      h = Curses.lines - 3 # title + tabs + status live outside the feed
      return h unless @tab.zero?

      w = Renderer.content_width(Curses.stdscr.maxx)
      count = 0
      used = 0
      visible_events.each do |e|
        ch = @renderer.card_height(e, w)
        break if used + ch > h && count.positive?

        used += ch
        count += 1
      end
      [count, 1].max
    end

    def paint
      events = visible_events
      width = Curses.stdscr.maxx
      height = Curses.lines - 3 # title + tabs + status live outside the feed
      cw = Renderer.content_width(width)  # centered reading column, not full bleed
      left = Renderer.content_left(width)
      lines =
        if @tab.zero?
          @renderer.display_lines(events, first_visible: @first_visible,
                                          height: height, width: cw,
                                          selected: @selected,
                                          resolve_reply: @timeline.method(:find),
                                          reactions: @timeline.method(:reaction_count),
                                          liked: ->(id) { @timeline.liked_by_me?(id, @info["me"]) })
        else
          @renderer.list_lines(list_items, first_visible: @first_visible,
                                           height: height, width: cw,
                                           selected: @selected)
        end
      rows = @renderer.changed_rows(lines)
      Curses.clear if rows == :all
      write_segs(0, @renderer.title_bar(online: @client&.connected? || false, width: width))
      write_segs(1, @renderer.tab_bar(@tab, width))
      if lines.empty?
        hint = @renderer.hint_line(empty_hint, cw)
        write_segs(2 + height / 2, hint, left, cw)
      else
        case rows
        when :all then lines.each_with_index { |line, i| write_segs(i + 2, line, left, cw) }
        when Array then rows.each { |i| write_segs(i + 2, lines[i], left, cw) }
        end
      end
      write_segs(Curses.lines - 1, @renderer.status_line(
        count: view_size, position: view_size.zero? ? 0 : @selected + 1,
        query: @tab.zero? ? @query : nil, width: width, noun: NOUNS[@tab],
        flash: flash_active? ? @flash : nil, hints: Renderer::HINTS[@tab]
      ))
      Curses.refresh
    end

    # Paint one styled line: each [text, style] segment, then pad the rest of
    # the row (no style) so stale glyphs can never survive a repaint.
    # With panel_width set, the segment area + inner pad still take the PANEL
    # pair (default background now); the outer margin stays on the terminal
    # background, so the paint path is unchanged.
    def write_segs(row, line, left = 0, panel_width = nil)
      return if row >= Curses.lines

      Curses.setpos(row, left)
      col = left
      line.segs.each do |text, style|
        attr = attr_for(style, !panel_width.nil?)
        if attr
          Curses.attron(attr) { Curses.addstr(text) }
        else
          Curses.addstr(text)
        end
        col += Renderer.dw(text)
      end
      if panel_width
        inner = left + panel_width - col
        if inner.positive?
          Curses.attron(Curses.color_pair(PANEL)) { Curses.addstr(" " * inner) }
        end
        outer = Curses.stdscr.maxx - left - panel_width
        Curses.addstr(" " * outer) if outer.positive?
      else
        rest = Curses.stdscr.maxx - col
        Curses.addstr(" " * rest) if rest.positive?
      end
    rescue RangeError
      nil # past the screen edge (tiny terminals)
    end

    def attr_for(style, panel = false)
      case style
      when :bar, :brand, :accent
        Curses.color_pair(panel ? ACCENT_PANEL : ACCENT) | Curses::A_BOLD
      when :name then Curses::A_BOLD | (panel ? Curses.color_pair(PANEL) : 0)
      when :dim, :time, :handle then Curses.color_pair(panel ? DIM_PANEL : DIM)
      when :active then Curses::A_BOLD | Curses::A_UNDERLINE
      else panel ? Curses.color_pair(PANEL) : nil
      end
    end

    def drain_socket(client)
      return unless client

      retry_reconnect(client) # a daemon restart must not strand the session
      while client.messages.length.positive?
        msg = client.messages.shift(true) rescue break
        next if msg.nil?

        drain(msg)
      end
    end

    # Dead-socket redial, throttled to one attempt per 2s. client#reconnect
    # replays hello + timeline + info, so the view refills on its own.
    def retry_reconnect(client)
      return if client.connected?

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @reconnect_at && now - @reconnect_at < 2

      @reconnect_at = now
      flash("reconnected to nostrd") if client.reconnect
    end

    # Anchor selection to the note, not the row: live arrivals must not drag it.
    def remember_selection
      @selected_id = selected_event&.id
    end

    def follow_selection
      return unless @screen_live # headless: nothing to scroll

      if @tab.zero?
        ensure_visible(visible_events, Curses.lines - 3,
                       Renderer.content_width(Curses.stdscr.maxx))
      else
        ensure_visible_flat(list_items.size, Curses.lines - 3)
      end
    end

    # Flat list tabs are 1 row per item: plain window arithmetic.
    def ensure_visible_flat(count, height)
      @first_visible = @selected if @selected < @first_visible
      @first_visible = @selected - height + 1 if @selected >= @first_visible + height
      @first_visible = @first_visible.clamp(0, [count - height, 0].max)
    end

    # Variable-height cards: scroll just far enough that the selected card's
    # last row is on screen (never more, so context above is preserved).
    # Each card height is computed once per call: O(n), not O(n²).
    def ensure_visible(events, height, width)
      @first_visible = @selected if @selected < @first_visible
      return if @selected <= @first_visible

      used = @renderer.card_height(events[@selected], width)
      start = @selected
      while start > @first_visible
        prev = @renderer.card_height(events[start - 1], width)
        break if used + prev > height

        start -= 1
        used += prev
      end
      @first_visible = start if start > @first_visible
    end

    def clamp_selection
      return unless @tab.zero?

      events = visible_events
      if events.empty?
        @selected = 0
        return
      end
      anchor = events.index { |e| e.id == @selected_id } if @selected_id
      @selected = anchor || @selected.clamp(0, events.size - 1)
      remember_selection
    end

    # --- SSS tab views: follows / relays / settings ---

    def list_items
      case @tab
      when 1 then follows_items
      when 2 then relays_items
      when 3 then chat_items
      when 4 then settings_items
      else []
      end
    end

    def follows_items
      (@info["follows"] || []).map do |pk|
        p = @timeline.profile_for(pk) || {}
        { label: p["display_name"] || p["name"] || "#{pk[0, 8]}…",
          sub: p["nip05"], right: "#{pk[0, 16]}…", pubkey: pk }
      end
    end

    # Gossip-style relay panel: URL + switch letters + live state. Switch
    # letters show the six toggles (R read · I inbox · W write · O outbox ·
    # D discover · S search); inactive ones render as "-". Keys: R I W O D S
    # toggle, a add, x remove, A advertise.
    def relays_items
      (@info["relays"] || []).map do |r|
        switches = %w[read inbox write outbox discover search]
                   .map { |k| r[k] == true ? k[0].upcase : "-" }
                   .join(" ")
        { label: r["url"].to_s, sub: switches,
          right: r["state"].to_s, up: r["state"] == "connected",
          url: r["url"].to_s,
          "read" => r["read"] == true, "inbox" => r["inbox"] == true,
          "write" => r["write"] == true, "outbox" => r["outbox"] == true,
          "discover" => r["discover"] == true, "search" => r["search"] == true }
      end
    end

    def settings_items
      mp = @info&.dig("my_profile") || {}
      name = (mp["display_name"] || mp["name"]).to_s
      rows = [{ label: "birdwatch 0.1", sub: "nostr TUI" }, # o → GitHub someday
              { label: "profile", sub: name.empty? ? "not set" : name, right: "e edit" },
              { label: "nostr connect", sub: "NIP-46 pairing", right: "o QR" }]
      rows << { label: "unlock", sub: "vault passphrase → sign again", right: "u" } if @info&.dig("locked")
      rows << { label: "logout", sub: "lock the daemon signer", right: "s" }
      rows << { label: "import key", sub: "nsec (nsec1… or hex) + passphrase", right: "i" }
      rows
    end

    def empty_hint
      case @tab
      when 1 then "no follows yet"
      when 2 then "no relays connected"
      when 3 then @chat_partner ? "no messages yet — m to write" : "no conversations yet — DMs land here"
      else "no notes yet — start nostrd or press n to post"
      end
    end

    def yank
      return unless selected_event

      id = Shellwords.escape(selected_event.id)
      copied = system("( printf %s #{id} | wl-copy ) 2>/dev/null") ||
               system("( printf %s #{id} | xclip -selection clipboard ) 2>/dev/null")
      copied || warn("yank: #{selected_event.id}")
    end

    # Gossip relay switches (relays tab only): R/I/W/O/D/S toggle, a adds a
    # relay, x removes it, A advertises.
    SWITCHES = { relay_read: "read", relay_inbox: "inbox", relay_write: "write",
                 relay_outbox: "outbox", relay_discover: "discover",
                 relay_search: "search" }.freeze
    def relay_command(action, client)
      return flash("relays tab only") unless @tab == 2

      if action == :relay_advertise
        ok = client&.advertise_relays
        return flash(ok ? "relay list advertised (kind 10002)" : "advertise failed (offline?)")
      end

      if action == :relay_add
        url = ask_line("add relay (wss://…): ")
        url = url.strip
        url = "wss://#{url}" if !url.empty? && !url.start_with?("ws")
        ok = url.start_with?("ws") && client&.relay_flags(
          url, read: true, inbox: false, write: true, outbox: false,
          discover: false, search: false)
        return flash(ok ? "added #{url}" : "add failed")
      end

      item = list_items[@selected]
      return flash("no relay selected") unless item

      if action == :relay_remove
        ok = client&.relay_remove(item[:url])
        return flash(ok ? "removed #{item[:url].delete_prefix('wss://')}" : "remove failed (offline?)")
      end

      url = item[:url]
      flags = item.dup # hash with string-symbol switch keys from relays_items
      key = SWITCHES[action]
      flags[key] = !flags[key]
      # gossip semantics: inbox implies read, outbox implies write
      flags["read"] = true if key == "inbox" && flags["inbox"]
      flags["write"] = true if key == "outbox" && flags["outbox"]
      ok = client&.relay_flags(url, read: flags["read"], inbox: flags["inbox"],
                               write: flags["write"], outbox: flags["outbox"],
                               discover: flags["discover"], search: flags["search"])
      flash(ok ? "#{url.delete_prefix('wss://')}: #{key} #{flags[key] ? 'on' : 'off'}"
               : "relay_flags failed (offline?)")
    end

    # NIP-25 like on the selected note; the daemon signs kind 7.
    # Settings tab: row-keyed actions — e/o/s/u/i act on the SELECTED row
    # (j/k to move). Keys mean nothing until a row is selected.
    # --- chat tab: NIP-17 DMs ---

    # Rows swap with mode: partner list (pubkey per row) or the open thread
    # (direction in the label; rumors only — no relay metadata involved).
    def chat_items
      if @chat_partner
        me = @info["me"].to_s
        @chat_msgs.map do |r|
          { label: r["pubkey"] == me ? "me" : chat_partner_name(r["pubkey"].to_s),
            sub: r["content"].to_s, right: chat_time(r["created_at"]) }
        end
      else
        @chat_convs.map do |c|
          { label: chat_partner_name(c["pubkey"].to_s),
            sub: (c["last"] || {})["content"].to_s,
            right: c["count"].to_s, pubkey: c["pubkey"] }
        end
      end
    end

    def chat_partner_name(pk)
      p = @timeline.profile_for(pk) || {}
      p["display_name"] || p["name"] || "#{pk[0, 8]}…"
    end

    def chat_time(ts)
      Time.at(ts.to_i).strftime("%m/%d %H:%M")
    rescue RangeError, TypeError
      ""
    end

    # The dms fetch rides its own sub so replies route back here (drain).
    def refresh_chat
      @dm_seq += 1
      @chat_fetch = "dms_#{@dm_seq}"
      @chat_msgs = [] if @chat_partner # stale rows out during refetch
      @client&.dms(partner: @chat_partner, limit: 50, sub: @chat_fetch)
    end

    # Enter toggles list ↔ open thread.
    def chat_enter(_client)
      return flash("chat tab only") unless @tab == 3

      if @chat_partner
        @chat_partner = nil
      else
        item = chat_items[@selected]
        return flash("no conversation selected") unless item && item[:pubkey]

        @chat_partner = item[:pubkey]
      end
      @selected = 0
      @first_visible = 0
      refresh_chat
    end

    # m in an open thread: compose, then the daemon seals/wraps/publishes.
    # The ack (dmsend_ id) triggers the refetch that shows our own message.
    def chat_compose(_client)
      return flash("open a thread first (Enter)") unless @tab == 3 && @chat_partner

      text = ask_line("message: ")
      return if text.nil? || text.empty? # ESC = cancel

      @client&.send_dm(@chat_partner, text) ? flash("sending…") : flash("offline?")
    end

    def settings_action(key, client)
      row = list_items[@selected]
      case [key, row && row[:label]]
      when ["e", "profile"] then profile_edit(client)
      when ["o", "nostr connect"] then request_connect_qr(client)
      when ["o", "birdwatch 0.1"] then open_external("xdg-open #{Shellwords.escape(GITHUB_URL)}")
      when ["s", "logout"] then signout(client)
      when ["u", "unlock"] then unlock_session(client)
      when ["i", "import key"] then import_key(client)
      else flash("no #{key} action on that row — select with j/k")
      end
    end

    # Vault passphrase, masked while typing; the daemon unlocks the signer.
    def unlock_session(client)
      pass = ask_line("vault passphrase: ", mask: true)
      return if pass.nil? || pass.empty?

      ok = client&.unlock(pass)
      flash(ok ? "unlocked — signing enabled" : "unlock failed (wrong passphrase?)")
    end

    # Import a secret key: nsec (or hex) + new vault passphrase. The daemon
    # re-encrypts the vault and unlocks; restart the daemon to re-key the
    # orchestrator (relays/ads follow the new identity).
    def import_key(client)
      nsec = ask_line("nsec (nsec1… or hex): ")
      return if nsec.nil? || nsec.strip.empty?

      pass = ask_line("new vault passphrase: ", mask: true)
      return if pass.nil? || pass.empty?

      ok = client&.import_key(nsec.strip, pass)
      flash(ok ? "key imported — restart daemon to switch (bin/nostr --stop && bin/nostr)"
               : "import failed (bad nsec?)")
    end

    # Settings tab: sign out — the daemon signer locks, so nothing can be
    # published from this machine until the vault passphrase unlocks it.
    def signout(client)
      ok = client&.signout
      flash(ok ? "signed out — signer locked" : "signout failed (offline?)")
    end

    # NIP-46 "nostr connect": the daemon IS the remote signer, so the phone
    # is the client: we show its persistent bunker URI (bunker://…?relay=…&
    # secret=…) as a QR — browser page first (qrencode), terminal QR as the
    # fallback. The secret never rotates, so re-pairing after a daemon
    # restart needs no new QR.

    # Settings tab: ask the daemon for the bunker URI. The answer lands in
    # drain("result") — async, so we only flash a hint here.
    def request_connect_qr(client)
      @connect_pending = true
      ok = client&.bunker_secret
      if ok
        flash("bunker URI を取得中…") unless @modal
      else
        @connect_pending = false
        flash("daemon に接続できません")
      end
    end

    # bunker URI -> terminal QR lines. Pure and headless-testable: half-block
    # pairs (two module rows per terminal row) with a 4-module quiet zone.
    # Raises LoadError (rqrcode gem missing) or ArgumentError (payload too
    # large for the level); callers fall back to the browser QR page.
    def self.qr_block_lines(uri, level: :l)
      require "rqrcode"
      qr = RQRCode::QRCode.new(uri.to_s, level: level)
      modules = qr.modules
      q = 4
      grid = Array.new(modules.size + 2 * q) { Array.new(modules.size + 2 * q, false) }
      modules.each_with_index do |row, y|
        row.each_with_index { |dark, x| grid[y + q][x + q] = dark }
      end
      grid.each_slice(2).map do |pair|
        top, bottom = pair
        top.each_index.map do |x|
          t = top[x]
          b = bottom ? bottom[x] : false
          t && b ? "█" : t ? "▀" : b ? "▄" : " "
        end.join
      end
    end

    # bunker URI -> QR: the browser page is the primary path (big, theme-
    # proof, easy for a phone camera — and it can't be closed by the feed
    # poll). Falls back to a terminal QR when qrencode is unavailable.
    def show_connect_modal
      uri = @bunker_uri.to_s
      return flash("bunker URI を取得できませんでした") if uri.empty?

      open_connect_page(uri)
    end

    # Primary connect QR: render the URI as SVG via qrencode, wrap it in a
    # local page, open it in the browser. Nothing leaves this machine — no
    # third-party QR service ever sees the URI. Fallback when qrencode is
    # missing/fails: terminal QR if it fits, else a text-only modal.
    def open_connect_page(uri)
      require "tempfile"
      svg = Tempfile.create(["birdwatch-bunker", ".svg"]) # 0600, unpredictable name
      svg_path = svg.path
      svg.close
      rendered = system("qrencode -t SVG -l M -m 2 -o #{Shellwords.escape(svg_path)} #{Shellwords.escape(uri)}")
      rendered &&= File.exist?(svg_path) && File.size(svg_path).positive?
      if rendered
        open_external("xdg-open #{Shellwords.escape(bunker_qr_page(uri, svg_path))}")
        flash("QRをブラウザで開きました — スマホで読み取って設定に貼り付け")
        return
      end
      lines = begin
        self.class.qr_block_lines(uri)
      rescue LoadError, StandardError
        nil
      end
      if terminal_fits?(lines)
        @modal = { uri: uri, qr: lines, width: lines.map { |l| Renderer.dw(l) }.max }
      else
        @modal = { uri: uri, qr: nil, width: [uri.length + 8, 60].min }
        flash("URI表示のみ — qrencode も rqrcode も無いため (gem install rqrcode 推奨)")
      end
    ensure
      File.delete(svg_path) if svg_path && File.exist?(svg_path)
    end

    # Terminal QR fit check; nil lines never fit. Curses is only up in the
    # live TUI, so headless callers (tests) can override this method.
    def terminal_fits?(lines)
      return false unless lines

      width = lines.map { |l| Renderer.dw(l) }.max
      width + 4 <= Curses.stdscr.maxx && lines.size + 7 <= Curses.lines
    end

    # Render the URI as an SVG QR via qrencode and wrap it in a tiny page.
    def bunker_qr_page(uri, svg_path)
      require "tempfile"
      page = Tempfile.create(["birdwatch-bunker", ".html"])
      page_path = page.path
      page.close
      File.write(page_path, <<~HTML)
        <!doctype html><html><head><meta charset="utf-8">
        <title>birdwatch · nostr connect</title>
        <style>body{background:#10131a;color:#e6e9f0;font-family:system-ui,sans-serif;
        display:flex;flex-direction:column;align-items:center;gap:1.25rem;padding:3rem}
        h1{font-size:1rem;font-weight:500;letter-spacing:.35em;margin:0}
        svg{background:#fff;border-radius:14px;padding:18px;width:min(62vmin,400px)}
        p{color:#99a;margin:0}code{max-width:92vw;overflow-wrap:anywhere;color:#8892a6}
        </style></head><body><h1>BIRDWATCH · NOSTR CONNECT</h1>
        #{File.read(svg_path)}
        <p>Scan with a NIP-46 client (bunker対応クライアント) to pair this device.</p>
        <code>#{CGI.escapeHTML(uri)}</code></body></html>
      HTML
      page_path
    end

    # Full-screen overlay: the QR on white cells so any phone camera reads it
    # regardless of terminal theme; URI below for reading/copying.
    def paint_modal
      scr = Curses.stdscr
      m = @modal
      uri_width = [[scr.maxx - 6, 44].min, 20].max
      body = ["NOSTR CONNECT · BUNKER", ""]
      body.concat(m[:qr]) if m[:qr]
      body << "" if m[:qr]
      body.concat(m[:uri].scan(/.{1,#{uri_width}}/))
      body << ""
      body << "スマホで読み取り → 設定に貼り付け (何かのキーで閉じる)"
      width = body.map { |l| Renderer.dw(l) }.max
      y0 = [(scr.maxy - body.size) / 2, 0].max
      x0 = [(scr.maxx - width) / 2, 0].max
      qr_from = m[:qr] ? 2 : nil
      qr_to = m[:qr] ? 2 + m[:qr].size : nil
      body.each_with_index do |line, i|
        row = y0 + i
        break if row >= scr.maxy - 1

        Curses.setpos(row, x0)
        qr_row = qr_from && i >= qr_from && i < qr_to
        style = if qr_row
                  Curses.color_pair(QR_PAIR)
                elsif i.zero?
                  Curses.color_pair(ACCENT)
                else
                  Curses.color_pair(DIM)
                end
        Curses.attron(style) { Curses.addstr(line) }
        rest = scr.maxx - x0 - Renderer.dw(line)
        if rest.positive?
          Curses.attron(Curses.color_pair(qr_row ? QR_PAIR : PANEL)) { Curses.addstr(" " * rest) }
        end
      end
      Curses.refresh
    end

    # Settings tab: edit my profile (kind 0) as one line of JSON in $EDITOR.
    def profile_edit(client)
      Curses.close_screen if @screen_live # hand the terminal back to $EDITOR
      content = profile_buffer
      @renderer.reset
      return if content.nil? || content.strip.empty? # editor left empty = cancel

      require "json"
      JSON.parse(content.strip) # raises → rescue flashes
      client&.update_profile(content.strip)
      flash("profile update sent (kind 0)")
    rescue JSON::ParserError
      flash("invalid profile JSON — not saved")
    end

    # The buffer: current profile as JSON on line 1, legend comments below.
    def profile_buffer
      require "tempfile"
      prof = @info&.dig("my_profile") || {}
      keep = %w[name display_name about picture nip05 banner website]
      tmp = Tempfile.create(["nostr-profile", ".json"]) # 0600, unpredictable name
      path = tmp.path
      tmp.close
      File.write(path, "#{JSON.generate(prof.slice(*keep))}\n# edit the JSON line above; clear it to cancel\n")
      system("#{editor_command(path, :insert)} > /dev/tty 2>&1")
      File.read(path).lines.reject { |l| l.start_with?("#") }.join
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    def like(client)      return flash("no note selected") unless @tab.zero? && selected_event

      ok = client&.like(id: selected_event.id, pubkey: selected_event.pubkey)
      flash(ok ? "liked +1" : "like failed (offline?)")
    end

    # Transient status-bar message; paints until expiry, auto-clears.
    def flash(text, ttl: 2)
      @flash = text
      @flash_until = Time.now + ttl
      nil
    end

    def flash_active?
      @flash && Time.now < @flash_until
    end

    # xdg-open children (and their "Opening in…" chatter) scribble on the
    # terminal behind the curses screen; suspend curses, run the command,
    # restore, then force a full repaint.
    # xdg-open children chatter ("Opening in…") scribbles on the terminal
    # behind the curses screen and the diff-repaint then misses the damage.
    # Keep curses live and just detach the child from the TTY entirely.
    def open_external(cmd)
      system("#{cmd} >/dev/null 2>&1 </dev/null")
      @renderer.reset
    end

    def open_link
      # Follows tab: open the profile on npub.world (accepts hex pubkeys).
      if @tab == 1
        pk = list_items.dig(@selected, :pubkey)
        return flash("no follow selected") unless pk

        open_external("xdg-open #{Shellwords.escape("https://npub.world/#{pk}")}")
        return
      end
      return unless selected_event

      link = @timeline.links(selected_event).first
      open_external("xdg-open #{Shellwords.escape(link)}") if link
    end

    def compose(client, reply_to:)
      Curses.close_screen # hand the terminal back to $EDITOR
      text = editor_buffer(reply_to)
      @renderer.reset
      return if text.nil? || text.strip.empty?

      if reply_to
        # NIP-22: replies are kind 1111 comments; tags live in the signed
        # event, the body stays plain text.
        client&.post_comment(text.strip, id: reply_to.id, pubkey: reply_to.pubkey,
                                        kind: reply_to.kind, tags: reply_to.tags)
      else
        client&.post_note(text.strip)
      end
    end

    def editor_buffer(reply_to)
      require "tempfile"
      tmp = Tempfile.create(["nostr-compose", ".md"]) # 0600, unpredictable name
      path = tmp.path
      tmp.close
      File.write(path, reply_to ? "RE: #{reply_to.author_short}\n" : "")
      system("#{editor_command(path, reply_to ? :reply : nil)} > /dev/tty 2>&1")
      File.read(path).lines.drop_while { |l| l.start_with?("RE: ") }.join
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    # Editor invocation with cursor positioning: :reply drops the cursor on
    # line 2 (below the "RE: <author>" header, straight into insert mode
    # where supported); :insert starts typing on line 1; nil opens plain.
    # Unknown editors just open the buffer as-is.
    def editor_command(path, mode)
      editor = ENV.fetch("EDITOR", "vi")
      return "#{editor} #{Shellwords.escape(path)}" unless mode

      base = File.basename(editor.to_s.split(/\s+/).first.to_s)
      # omarchy's EDITOR is a wrapper ("omarchy-launch-editor --inline <args>")
      # that execs the real editor (helix here) with every argument after
      # --inline — resolve it so cursor flags match what will actually run.
      base = omarchy_inline_editor if base == "omarchy-launch-editor"

      if mode == :insert && %w[vim nvim].include?(base)
        return "#{editor} +startinsert #{Shellwords.escape(path)}"
      end
      return "#{editor} #{Shellwords.escape(path)}" if mode == :insert

      case base
      when "vim", "nvim" then "#{editor} +\"2\" +startinsert #{Shellwords.escape(path)}"
      when "vi", "view"  then "#{editor} +\"2\" #{Shellwords.escape(path)}"
      # helix/nano/emacs all take +N (helix: "open the first file at line N")
      when "nano", "emacs", "emacsclient", "hx", "helix" then "#{editor} +2 #{Shellwords.escape(path)}"
      else "#{editor} #{Shellwords.escape(path)}"
      end
    end

    # The omarchy default editor, resolved once (~/.local/state/omarchy/defaults/editor).
    def omarchy_inline_editor
      return @inline_editor if defined?(@inline_editor)

      path = File.expand_path("~/.local/state/omarchy/defaults/editor")
      tok = File.readable?(path) ? File.read(path).strip.split(/\s+/).first : nil
      @inline_editor = tok && !tok.empty? ? File.basename(tok) : nil
    rescue StandardError
      @inline_editor = nil
    end

    # getch yields printable chars as (possibly multibyte UTF-8) Strings and
    # control chars as Integers; both are handled here.
    def ask_line(prompt, mask: false)
      row = Curses.lines - 1
      width = Curses.stdscr.maxx
      buf = +""
      Curses.curs_set(1)
      loop do
        shown = mask ? "•" * buf.length : buf
        draw_prompt(row, width, prompt, shown)
        ch = Curses.getch
        case ch
        when 10, 13, "\n", "\r" then break
        when 27, "\e" then buf = nil; break # ESC cancels (and short-circuits on nil!)
        when Curses::Key::BACKSPACE, 127, 8, "\b", "\u007F" then buf = buf[0...-1].to_s
        when String then buf << ch
        when 32..126 then buf << ch.chr
        when 128..255
          # Single UTF-8 byte without a locale: buffer until the sequence
          # is valid, then splice it in as UTF-8.
          (@pending ||= +"").<<(ch.chr).force_encoding(Encoding::BINARY)
          if (chunk = @pending.dup.force_encoding(Encoding::UTF_8)).valid_encoding?
            buf << chunk
            @pending = +""
          end
        end
      end
      Curses.curs_set(0)
      buf
    end

    def draw_prompt(row, width, prompt, buf)
      Curses.setpos(row, 0)
      Curses.attron(Curses.color_pair(ACCENT) | Curses::A_BOLD) do
        Curses.addstr((prompt + buf).slice(0, width).ljust(width))
      end
    end
  end
end
