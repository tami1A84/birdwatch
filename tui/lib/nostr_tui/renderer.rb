# frozen_string_literal: true

module NostrTui
  # Terminal-independent rendering: turns a timeline into styled "cards" and
  # computes which rows changed. Every line is a list of [text, style] segments
  # (style: nil, :bar, :brand, :name, :dim); the curses shell only paints what
  # it is given, so all layout decisions live here.
  #
  # Visual skin: a Death Stranding "SSS" homage — cyan accent, thin white
  # title, 〈 selected 〉 tab strip, flat list views for follows/relays/settings.
  # Wide terminals: the feed is a centered reading column (App paints it at
  # content_left, panel-styled); chrome stays full width. Card time moved to
  # the bottom meta row (the DS reaction-row slot).
  #
  # Card layout (monospace):
  #   ▌ ● Alice  @alice@zaps.lol
  #     note content, word-wrapped, hard-chopped CJK-safe (max BODY_MAX lines)
  #     ↩ replying to Bob                                    12m
  #   (one blank line of air between cards)
  class Renderer
    Line = Struct.new(:segs) do
      def text = segs.sum("") { |seg| seg[0] }
    end

    BAR = "▌"
    BODY_MAX = 6
    NAME_MAX = 20
    HANDLE_MAX = 24
    # Reading measure: the feed column never exceeds this (centered on wider
    # terminals — a full-bleed card row on a 150-col screen reads as a void).
    CONTENT_MAX = 84
    # SSS header tabs (h/l, ←/→, 1-5).
    TABS = ["ホーム", "フォロー", "リレー", "チャット", "設定"].freeze

    # Per-tab status-bar hints (indexed by tab): the relays tab surfaces its
    # own editing keys, follows swaps like/reply for the profile opener.
    HINTS = [
      "h/l tabs · j/k move · g/G ends · L like · b upload · n post · r reply · y yank · o open · q quit",
      "h/l tabs · j/k move · g/G ends · o profile · q quit",
      "R/I/W/O/D/S switch · a add · x remove · A advertise · h/l tabs · q quit",
      "Enter open/close · m send · h/l tabs · q quit",
      "e profile · o QR · s logout · u unlock · i import · h/l tabs · q quit"
    ].freeze

    # East-Asian wide / emoji code points count as 2 terminal cells.
    # NOTE: keep on one line — inside a character class, /x whitespace is literal.
    WIDE = /[\u1100-\u115F\u2E80-\u303F\u3041-\u30FF\u3105-\u312F\u3131-\u318E\u3190-\u31FF\u3400-\u4DBF\u4E00-\u9FFF\uA000-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE10-\uFE6F\uFF00-\uFF60\uFFE0-\uFFE6\u{1F300}-\u{1FAFF}]/

    class << self
      def dw(str) = str.each_char.sum(0) { |c| c.match?(WIDE) ? 2 : 1 }

      # Trim to at most max display cells, appending "…" when cut.
      def ellipsize(str, max)
        return str if dw(str) <= max

        out = +""
        str.each_char do |c|
          break if dw(out) + dw(c) + 1 > max # +1 reserves the "…"

          out << c
        end
        out + "…"
      end

      # Feed column geometry: capped measure, centered on wide terminals.
      def content_width(width) = [width, CONTENT_MAX].min

      def content_left(width) = (width - content_width(width)) / 2

      # Modern-SNS relative time: now / 12m / 3h / 2d, then a date.
      # Future timestamps (clock skew) read as "now".
      def time_label(created_at, now = Time.now)
        t = Time.at(created_at.to_i)
        s = now.to_i - t.to_i
        return "now" if s < 60
        return "#{s / 60}m" if s < 3600
        return "#{s / 3600}h" if s < 86_400
        return "#{s / 86_400}d" if s < 7 * 86_400
        return t.strftime("%m-%d") if t.year == now.year

        t.strftime("%Y-%m-%d")
      end
    end

    def initialize
      @last_lines = nil
    end

    # Cards fitting in `height` rows, starting at card `first_visible`.
    # A card that would not fully fit is deferred to the next frame, so the
    # layout is stable between paints.
    def display_lines(events, first_visible:, height:, width:, selected:,
                      resolve_reply: nil, now: Time.now, reactions: nil, liked: nil)
      lines = []
      events[first_visible..].to_a.each_with_index do |event, i|
        card = card(event, width, selected: first_visible + i == selected,
                                    resolve_reply: resolve_reply, now: now,
                                    reactions: reactions, liked: liked)
        break if lines.any? && lines.size + card.size > height

        lines.concat(card)
        break if lines.size >= height
      end
      lines
    end

    def card_height(event, width)
      @height_cache ||= {}
      @height_cache.clear if @height_cache.size > 2000
      @height_cache[[event.id, width]] ||= 1 + body_lines(event, width).size + 2 # meta + air
    end

    # Diff-based repaint plan; compares concatenated text (style-only changes
    # always co-occur with a text change, e.g. the selection bar glyph).
    def changed_rows(new_lines)
      texts = new_lines.map(&:text)
      return :all if @last_lines.nil? || @last_lines.size != texts.size

      rows = (0...texts.size).reject { |i| @last_lines[i] == texts[i] }
      rows.empty? ? [] : rows
    ensure
      @last_lines = texts
    end

    # Force the next paint to redraw everything (after curses was suspended
    # for an external child that scribbled on the terminal).
    def reset
      @last_lines = nil
    end

    # Force the next paint to redraw everything (after curses was suspended).
    def reset = (@last_lines = nil)

    def title_bar(online:, width:)
      right = online ? "ONLINE" : "OFFLINE"
      pad = [width - 10 - 7 - right.length, 1].max
      Line.new([[" BIRDWATCH", nil], ["  nostr", :dim],
                [" " * pad, nil], [right, online ? :accent : :dim]])
    end

    # SSS tab strip: 〈 active 〉 with | separators.
    def tab_bar(index, width)
      segs = [["  ", nil]]
      TABS.each_with_index do |label, i|
        if i == index
          segs << ["〈 ", :accent] << [label, :active] << [" 〉", :accent]
        else
          segs << [label, :dim]
        end
        segs << ["  |  ", :dim] if i < TABS.size - 1
      end
      Line.new(segs)
    end

    def status_line(count:, position:, query:, width:, noun: "notes", flash: nil, hints: HINTS[0])
      left = +" ▸ #{position}/#{count} #{noun}"
      left << "  q:#{query}" if query
      right = flash || hints
      pad = [width - self.class.dw(left) - self.class.dw(right), 1].max
      Line.new([[left, :bar], [" " * pad, nil], [self.class.ellipsize(right, width - self.class.dw(left) - 1), flash ? :bar : :dim]])
    end

    def hint_line(text, width)
      pad = [(width - self.class.dw(text)) / 2, 0].max
      Line.new([[" " * pad + text, :dim]])
    end

    # Flat one-row-per-item views (follows / relays / settings tabs).
    def list_lines(items, first_visible:, height:, width:, selected:)
      items[first_visible, height].to_a.map.with_index do |item, i|
        list_row(item, width, selected: first_visible + i == selected)
      end
    end

    def list_row(item, width, selected:)
      right = item[:right].to_s
      rw = self.class.dw(right) # reserve exactly its cells; pad fills the rest
      label = self.class.ellipsize(item[:label].to_s, [width - 6 - rw, 3].max)
      # Relay tab rows carry :up — the dot reflects live state (gossip-like),
      # not just selection.
      dot, dot_style = if item.key?(:up)
                         item[:up] ? ["● ", :accent] : ["○ ", :dim]
                       else
                         ["● ", selected ? :accent : :dim]
                       end
      segs = [[selected ? BAR : " ", selected ? :bar : nil], [" ", nil],
              [dot, dot_style], [label, :name]]
      used = 4 + self.class.dw(label)
      if (sub = item[:sub])
        txt = self.class.ellipsize("  #{sub}", [width - used - rw - 1, 0].max)
        unless txt.empty?
          segs << [txt, :dim]
          used += self.class.dw(txt)
        end
      end
      segs << [" " * [width - used - rw, 1].max, nil]
      segs << [right, :dim] unless right.empty?
      Line.new(segs)
    end

    private

    def card(event, width, selected:, resolve_reply:, now: Time.now,
             reactions: nil, liked: nil)
      lines = [Line.new(header(event, selected, width))]
      body_lines(event, width).each do |l|
        lines << Line.new([[l, nil]])
      end
      lines << Line.new(meta_row(event, width, now, resolve_reply,
                                 reactions: reactions, liked: liked))
      lines << Line.new([["", nil]])
      lines
    end

    # SSS card head: avatar dot + bold name (+ handle). No time here anymore.
    def header(event, selected, width)
      label = self.class.ellipsize(event.author_short.to_s, [width - 8, 3].max)
      segs = [[selected ? BAR : " ", selected ? :bar : nil], [" ", nil],
              ["● ", selected ? :accent : :dim], [label, :name]]
      if (handle = event.author_handle)
        htxt = "  @#{handle}"
        htxt = self.class.ellipsize(htxt, [width - 6 - self.class.dw(label), 0].max)
        segs << [htxt, :handle] if self.class.dw(htxt) >= 4
      end
      segs
    end

    # Bottom meta row (DS reaction-row slot): reply context, time. The 👍
    # badge renders ONLY on notes I liked myself — other people's reactions
    # stay invisible so the timeline stays quiet.
    def meta_row(event, width, now, resolve_reply, reactions: nil, liked: nil)
      time = self.class.time_label(event.created_at, now)
      reply = has_reply?(event) ? reply_meta(event, resolve_reply) : nil
      n = reactions ? reactions.call(event.id) : 0
      mine = liked ? liked.call(event.id) : false
      like = mine ? "👍#{n}✓" : nil
      used = 2 + (like ? self.class.dw(like) + 1 : 0) + (reply ? self.class.dw(reply) : 0)
      segs = [["  ", nil]]
      segs << [like, mine ? :accent : :dim] if like
      segs << [" ", nil] if like
      segs << [reply, :dim] if reply
      segs << [" " * [width - used - time.length, 1].max, nil]
      segs << [time, :time]
      segs
    end

    def body_lines(event, width)
      cw = [width - 4, 10].max
      wrapped = wrap(event.content, cw)
      out = wrapped.first(BODY_MAX).map { |l| "  #{l}" }
      out << "  …" if wrapped.size > BODY_MAX
      out
    end

    def reply_meta(event, resolve_reply)
      e_id = event.tags.reverse.find { |t| t.is_a?(Array) && t[0] == "e" }&.at(1)
      who = e_id && resolve_reply ? resolve_reply.call(e_id)&.author_short : nil
      "↩ replying to #{who || "note #{e_id[0, 8]}"}"
    end

    def has_reply?(event)
      event.tags.any? { |t| t.is_a?(Array) && t[0] == "e" }
    end

    # Greedy word wrap by display width; oversized tokens (URLs, unspaced CJK)
    # are hard-chopped at the column edge.
    def wrap(text, width)
      out = []
      text.to_s.split("\n", -1).each do |para|
        if para.strip.empty?
          out << ""
          next
        end
        line = +""
        para.split(/\s+/).each do |word|
          word = word.dup
          while self.class.dw(word) > width
            if line.empty?
              take = take_width(word, width)
              out << take
              word = word[take.length..]
            else
              out << line
              line = +""
            end
          end
          if line.empty?
            line = word.dup
          elsif self.class.dw(line) + 1 + self.class.dw(word) <= width
            line << " " << word
          else
            out << line
            line = word.dup
          end
        end
        out << line unless line.empty?
      end
      out.empty? ? [""] : out
    end

    def take_width(word, width)
      used = 0
      word.chars.each_with_index do |c, i|
        cw = self.class.dw(c)
        return word[0, i] if used + cw > width

        used += cw
      end
      word
    end
  end
end
