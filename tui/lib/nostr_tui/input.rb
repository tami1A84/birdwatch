# frozen_string_literal: true

require "json"

module NostrTui
  # Keymap, line-reading, and omarchy editor detection.  Zero UI layout.
  class Input
    ACCENT = 1; DIM = 2; PANEL = 3; ACCENT_PANEL = 4; DIM_PANEL = 5; QR_PAIR = 6

    KEYMAP = {
      "j" => :down, "k" => :up, "g" => :top, "G" => :bottom,
      "h" => :tab_prev, "l" => :tab_next,
      "1" => :tab1, "2" => :tab2, "3" => :tab3, "4" => :tab4,
      :pgup => :page_up, :pgdn => :page_down,
      "/" => :search, "r" => :reply, "n" => :compose,
      "b" => :blob_put, "N" => :compose_editor,
      "L" => :like,
      "R" => :relay_read, "I" => :relay_inbox, "W" => :relay_write,
      "O" => :relay_outbox, "D" => :relay_discover, "S" => :relay_search,
      "a" => :relay_add, "x" => :relay_remove, "A" => :relay_advertise,
      "F" => :blossom_fetch, "E" => :blossom_edit, "P" => :blossom_publish,
      "y" => :yank, "o" => :open, "e" => :profile_edit, "s" => :signout,
      "i" => :import_key, "u" => :unlock,
      "q" => :quit, 27 => :quit
    }.freeze

    GITHUB_URL = "https://github.com/tami1A84/birdwatch"
    NOUNS = %w[notes follows relays items].freeze

    SWITCHES = {
      relay_read: "read", relay_inbox: "inbox", relay_write: "write",
      relay_outbox: "outbox", relay_discover: "discover",
      relay_search: "search"
    }.freeze

    def self.translate(key)
      key = case key
            when Curses::Key::DOWN then "j"
            when Curses::Key::UP then "k"
            when Curses::Key::LEFT then "h"
            when Curses::Key::RIGHT then "l"
            when Curses::Key::PPAGE then :pgup
            when Curses::Key::NPAGE then :pgdn
            else key
            end
      key
    end

    def self.ask_line(prompt, mask: false)
      row = Curses.lines - 1; width = Curses.stdscr.maxx; buf = +""
      Curses.curs_set(1); pending = +""
      loop do
        shown = mask ? "•" * buf.length : buf
        Input.draw_prompt(row, width, prompt, shown)
        ch = Curses.getch
        case ch
        when 10, 13, "\n", "\r" then break
        when 27, "\e" then buf = nil; break
        when Curses::Key::BACKSPACE, 127, 8, "\b", "\u007F" then buf = buf[0...-1].to_s
        when String then buf << ch
        when 32..126 then buf << ch.chr
        when 128..255
          pending << ch.chr.force_encoding(Encoding::BINARY)
          if (chunk = pending.dup.force_encoding(Encoding::UTF_8)).valid_encoding?
            buf << chunk; pending.replace("")
          end
        end
      end
      Curses.curs_set(0); buf
    end

    def self.draw_prompt(row, width, prompt, buf)
      Curses.setpos(row, 0)
      Curses.attron(Curses.color_pair(Input::ACCENT) | Curses::A_BOLD) do
        Curses.addstr((prompt + buf).slice(0, width).ljust(width))
      end
    end

    def self.omarchy_inline_editor
      return @inline_editor if defined?(@inline_editor)
      path = File.expand_path("~/.local/state/omarchy/defaults/editor")
      tok = File.readable?(path) ? File.read(path).strip.split(/\s+/).first : nil
      @inline_editor = tok && !tok.empty? ? File.basename(tok) : nil
    rescue StandardError
      @inline_editor = nil
    end

    def self.empty_hint(tab)
      case tab
      when 1 then "no follows yet"
      when 2 then "no relays — add with 'a'"
      else "no notes yet — start nostrd or post with 'n'"
      end
    end
  end
end
