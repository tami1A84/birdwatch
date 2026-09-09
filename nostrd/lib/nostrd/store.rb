# frozen_string_literal: true

require "sqlite3"
require "json"
require_relative "../nostr_core/event"
require_relative "../nostr_core/person_relay"
require_relative "../nostr_core/relay"

module Nostrd
  # SQLite is the single source of truth (WAL mode).
  # The TUI and the Rails PWA are both just socket clients of this data.
  class Store
    def initialize(path)
      @db = path == ":memory:" ? SQLite3::Database.new(path) :
        SQLite3::Database.new(path).tap { |d| d.execute("PRAGMA journal_mode=WAL") }
      @db.results_as_hash = false
      migrate
    end

    def migrate
      @db.execute <<~SQL
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY, pubkey TEXT NOT NULL, created_at INTEGER NOT NULL,
          kind INTEGER NOT NULL, content TEXT NOT NULL, tags TEXT NOT NULL)
      SQL
      @db.execute "CREATE INDEX IF NOT EXISTS idx_events_time ON events(created_at DESC)"
      @db.execute <<~SQL
        CREATE TABLE IF NOT EXISTS relays (
          url TEXT PRIMARY KEY, rank INTEGER NOT NULL DEFAULT 5,
          success_count INTEGER NOT NULL DEFAULT 0, successes INTEGER NOT NULL DEFAULT 0,
          connected INTEGER NOT NULL DEFAULT 0)
      SQL
      @db.execute <<~SQL
        CREATE TABLE IF NOT EXISTS person_relays (
          pubkey TEXT NOT NULL, url TEXT NOT NULL, write INTEGER NOT NULL DEFAULT 0,
          read INTEGER NOT NULL DEFAULT 0, last_fetched INTEGER, last_suggested INTEGER,
          list_updated INTEGER,
          PRIMARY KEY (pubkey, url))
      SQL
      @db.execute <<~SQL
        CREATE TABLE IF NOT EXISTS profiles (
          pubkey TEXT PRIMARY KEY, name TEXT, display_name TEXT, nip05 TEXT,
          picture TEXT, about TEXT, created_at INTEGER NOT NULL DEFAULT 0)
      SQL
      @db.execute "CREATE TABLE IF NOT EXISTS follows (pubkey TEXT PRIMARY KEY)"
      @db.execute <<~SQL
        CREATE TABLE IF NOT EXISTS my_relays (
          url TEXT PRIMARY KEY, read INTEGER NOT NULL DEFAULT 1,
          inbox INTEGER NOT NULL DEFAULT 0, write INTEGER NOT NULL DEFAULT 1,
          outbox INTEGER NOT NULL DEFAULT 0, discover INTEGER NOT NULL DEFAULT 0,
          search INTEGER NOT NULL DEFAULT 0)
      SQL
      # Older installs: add the search switch in place.
      cols = @db.execute("PRAGMA table_info(my_relays)").map { |c| c[1] }
      @db.execute "ALTER TABLE my_relays ADD COLUMN search INTEGER NOT NULL DEFAULT 0" unless
        cols.include?("search")
    end

    # --- my relay configuration (gossip-style switches) ---

    # Local switches only. inbox/outbox are the *advertised* halves; read and
    # write also cover the hidden (unadvertised) usage gossip supports.
    def my_relays
      @db.execute(
        "SELECT url, read, inbox, write, outbox, discover, search FROM my_relays ORDER BY url"
      ).map do |url, read, inbox, write, outbox, discover, search|
        { "url" => NostrCore.normalize_relay_url(url), "read" => read == 1, "inbox" => inbox == 1,
          "write" => write == 1, "outbox" => outbox == 1, "discover" => discover == 1,
          "search" => search == 1 }
      end
    end

    def my_relay(url)
      my_relays.find { |r| r["url"] == NostrCore.normalize_relay_url(url) }
    end

    def upsert_my_relay(url, read:, inbox:, write:, outbox:, discover:, search: false)
      @db.execute(
        "INSERT OR REPLACE INTO my_relays VALUES (?,?,?,?,?,?,?)",
        [NostrCore.normalize_relay_url(url), read ? 1 : 0, inbox ? 1 : 0, write ? 1 : 0,
         outbox ? 1 : 0, discover ? 1 : 0, search ? 1 : 0]
      )
    end

    def remove_my_relay(url)
      @db.execute "DELETE FROM my_relays WHERE url = ?", [NostrCore.normalize_relay_url(url)]
    end

    # --- follows (persisted; --follow args and socket `follow` land here) ---
    def save_follow(pubkey)
      @db.execute "INSERT OR IGNORE INTO follows (pubkey) VALUES (?)", [pubkey]
    end

    def follows
      @db.execute("SELECT pubkey FROM follows ORDER BY pubkey").flatten
    end

    def remove_follow(pubkey)
      @db.execute "DELETE FROM follows WHERE pubkey = ?", [pubkey]
    end

    # --- events ---

    def upsert_event(event)
      @db.execute(
        "INSERT OR IGNORE INTO events VALUES (?,?,?,?,?,?)",
        [event.id, event.pubkey, event.created_at, event.kind, event.content, JSON.generate(event.tags)]
      )
    end

    # Home feed: notes AND NIP-22 comments (kind 1111) thread together.
    def timeline(limit: 100, kind: nil)
      # kind 7 (NIP-25 reactions) rides the same frame; the TUI indexes it
      # into 👍 counts instead of showing it as a note.
      where = kind ? "WHERE kind = ?" : "WHERE kind IN (1, 7, 1111)"
      args = kind ? [kind, limit] : [limit]
      @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
        "#{where} ORDER BY created_at DESC LIMIT ?",
        args
      ).map { |row| row_to_event(row) }
    end

    # My kind-10002 relay list as {url, read, write} hashes (NIP-65: a nil
    # marker means the relay is both read and write).
    def relay_list_for(pubkey)
      row = @db.execute(
        "SELECT tags FROM events WHERE pubkey = ? AND kind = 10002 " \
        "ORDER BY created_at DESC LIMIT 1", [pubkey]
      ).first
      return [] unless row

      JSON.parse(row[0]).filter_map do |t|
        next unless t.is_a?(Array) && t[0] == "r" && t[1].to_s.start_with?("ws")

        { "url" => t[1], "read" => t[2].nil? || t[2] == "r", "write" => t[2].nil? || t[2] == "w" }
      end
    end

    def find_event(id)
      row = @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events WHERE id = ?", [id]
      ).first
      row && row_to_event(row)
    end

    # NIP-22 comments rooted at a note (uppercase "E" tag). GLOB keeps the
    # match case-sensitive so lowercase "e" (direct parent) never leaks in.
    def find_comments(root_id)
      @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
        "WHERE kind = 1111 AND tags GLOB ? ORDER BY created_at ASC",
        ['*["E","' + root_id + '"]*']
      ).map { |row| row_to_event(row) }
    end

    # NIP-25 reactions targeting an event ("e" tag).
    def find_reactions(target_id)
      @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
        "WHERE kind = 7 AND tags GLOB ? ORDER BY created_at ASC",
        ['*["e","' + target_id + '"]*']
      ).map { |row| row_to_event(row) }
    end

    # A single author's kind-1 notes (profile page), newest first.
    def timeline_by_author(pubkey, limit: 50)
      @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
        "WHERE pubkey = ? AND kind = 1 ORDER BY created_at DESC LIMIT ?",
        [pubkey, limit]
      ).map { |row| row_to_event(row) }
    end

    def purge_events(ids)
      ids = Array(ids).compact.uniq
      return 0 if ids.empty?

      placeholders = ids.map { "?" }.join(",")
      @db.execute("DELETE FROM events WHERE id IN (#{placeholders})", ids)
      @db.changes
    end

    # Socket `search` op: cached notes/comments by content plus profiles by
    # name / display_name / NIP-05 / pubkey prefix. ASCII case-insensitive.
    def search(query, limit: 50)
      escaped = query.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
      like = "%#{escaped}%"
      notes = @db.execute(
        "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
        "WHERE kind IN (1, 1111) AND content LIKE ? ESCAPE '\\' " \
        "ORDER BY created_at DESC LIMIT ?",
        [like, limit]
      ).map { |row| row_to_event(row) }
      profiles = @db.execute(
        "SELECT pubkey, name, display_name, nip05, picture, about FROM profiles " \
        "WHERE name LIKE ? ESCAPE '\\' OR display_name LIKE ? ESCAPE '\\' " \
        "OR nip05 LIKE ? ESCAPE '\\' OR pubkey LIKE ? LIMIT ?",
        [like, like, like, "#{escaped}%", limit]
      ).map do |pubkey, name, display_name, nip05, picture, about|
        { "pubkey" => pubkey, "name" => name, "display_name" => display_name,
          "nip05" => nip05, "picture" => picture, "about" => about }
      end
      [notes, profiles]
    end

    # --- profiles (kind 0 metadata: display name, NIP-05, ...) ---

    # Replaceable-event semantics: only a metadata at least as new wins.
    def upsert_profile(event, now = event.created_at)
      meta = begin
        JSON.parse(event.content.is_a?(String) ? event.content : event.content.to_s)
      rescue JSON::ParserError
        {}
      end
      clean = ->(v) { v.nil? || v.to_s.strip.empty? ? nil : v.to_s }
      @db.execute(
        "INSERT INTO profiles (pubkey, name, display_name, nip05, picture, about, created_at) " \
        "VALUES (?,?,?,?,?,?,?) " \
        "ON CONFLICT(pubkey) DO UPDATE SET " \
        "name=excluded.name, display_name=excluded.display_name, nip05=excluded.nip05, " \
        "picture=excluded.picture, about=excluded.about, created_at=excluded.created_at " \
        "WHERE excluded.created_at >= profiles.created_at",
        [event.pubkey, clean.call(meta["name"]), clean.call(meta["display_name"]),
         clean.call(meta["nip05"]), clean.call(meta["picture"]), clean.call(meta["about"]),
         now.to_i]
      )
    end

    PROFILE_COLS = "pubkey, name, display_name, nip05, picture, about"

    def profile_for(pubkey) = profiles_for([pubkey])[pubkey]

    # pubkey => profile hash; missing profiles are simply absent from the map.
    def profiles_for(pubkeys)
      pks = pubkeys.uniq
      return {} if pks.empty?

      marks = Array.new(pks.size, "?").join(",")
      @db.execute(
        "SELECT #{PROFILE_COLS} FROM profiles WHERE pubkey IN (#{marks})", pks
      ).to_h do |row|
        [row[0], { "pubkey" => row[0], "name" => row[1], "display_name" => row[2],
                   "nip05" => row[3], "picture" => row[4], "about" => row[5] }]
      end
    end

    def newest_profile_at(pubkey)
      @db.execute("SELECT created_at FROM profiles WHERE pubkey = ?", [pubkey]).first&.first
    end

    # --- relays ---

    def upsert_relay(relay)
      @db.execute(
        "INSERT OR REPLACE INTO relays VALUES (?,?,?,?,?)",
        [NostrCore.normalize_relay_url(relay.url), relay.rank, relay.success_count,
         relay.successes, relay.connected? ? 1 : 0]
      )
    end

    def relay(url)
      row = @db.execute(
        "SELECT url, rank, success_count, successes, connected FROM relays WHERE url = ?",
        [NostrCore.normalize_relay_url(url)]
      ).first
      row && row_to_relay(row)
    end

    def record_relay_result(url, success:)
      url = NostrCore.normalize_relay_url(url)
      @db.execute(
        "INSERT INTO relays(url) VALUES (?) ON CONFLICT(url) DO NOTHING", [url]
      )
      @db.execute(
        "UPDATE relays SET success_count = success_count + 1, successes = successes + ? WHERE url = ?",
        [success ? 1 : 0, url]
      )
    end

    # --- evidence maintenance (Seeker + fetch learning) ---

    # Parse an author's kind 10002 tags: ["r", url, "w"|"r"|nil].
    def upsert_person_relay_list(pubkey, tags, now)
      @db.execute "DELETE FROM person_relays WHERE pubkey = ? AND list_updated IS NOT NULL", [pubkey]
      tags.each do |tag|
        next unless tag.is_a?(Array) && tag[0] == "r"

        url = NostrCore.normalize_relay_url(tag[1])
        marker = tag[2]
        next unless url.start_with?("ws")

        write = marker.nil? || marker == "w" ? 1 : 0
        read = marker.nil? || marker == "r" ? 1 : 0
        @db.execute(
          "INSERT OR REPLACE INTO person_relays VALUES (?,?,?,?,?,?,?)",
          [pubkey, url, write, read, nil, nil, now]
        )
      end
    end

    # Empirical evidence: we fetched this person's events from this relay.
    def record_fetch(url, pubkey, now)
      url = NostrCore.normalize_relay_url(url)
      @db.execute(
        "INSERT OR IGNORE INTO person_relays VALUES (?,?,?,?,?,?,?)",
        [pubkey, url, 0, 0, nil, nil, nil]
      )
      @db.execute "UPDATE person_relays SET last_fetched = ? WHERE pubkey = ? AND url = ?",
                  [now, pubkey, url]
    end

    def newest_relay_list_at(pubkey)
      row = @db.execute "SELECT MAX(list_updated) FROM person_relays WHERE pubkey = ?", [pubkey]
      row.dig(0, 0)
    end

    # --- person ↔ relay evidence ---

    def upsert_person_relay(pubkey, pr)
      @db.execute(
        "INSERT OR REPLACE INTO person_relays VALUES (?,?,?,?,?,?)",
        [pubkey, NostrCore.normalize_relay_url(pr.url), pr.write ? 1 : 0, pr.read ? 1 : 0,
         pr.last_fetched, pr.last_suggested]
      )
    end

    # Best relays for one person, scored gossip-style:
    # association_score(person, relay) × relay.adjusted_score. Sorted desc.
    # Rows collapse onto the canonical (trailing-slash-free) url and their
    # evidence unions: legacy stores hold both spellings, and treating them
    # as two relays double-counted claims and dialed the relay twice.
    def best_relays_for(pubkey, usage: :outbox, now: Time.now.to_i)
      pr_rows = @db.execute(
        "SELECT url, write, read, last_fetched, last_suggested FROM person_relays WHERE pubkey = ?",
        [pubkey]
      )
      return [] if pr_rows.empty?

      relay_urls = pr_rows.map(&:first)
      placeholders = relay_urls.map { "?" }.join(",")
      relays = @db.execute(
        "SELECT url, rank, success_count, successes, connected FROM relays " \
        "WHERE url IN (#{placeholders})", relay_urls
      ).to_h { |r| [NostrCore.normalize_relay_url(r[0]), row_to_relay(r)] }

      merged = {}
      pr_rows.each do |url, write, read, lf, ls|
        key = NostrCore.normalize_relay_url(url)
        next unless (relay = relays[key])

        slot = (merged[key] ||= { relay: relay, write: 0, read: 0, last_fetched: nil, last_suggested: nil })
        slot[:write] = 1 if write == 1
        slot[:read] = 1 if read == 1
        slot[:last_fetched] = lf if lf && (!slot[:last_fetched] || lf > slot[:last_fetched])
        slot[:last_suggested] = ls if ls && (!slot[:last_suggested] || ls > slot[:last_suggested])
      end

      merged.filter_map do |url, e|
        pr = NostrCore::PersonRelay.new(url: url, write: e[:write] == 1, read: e[:read] == 1,
                                        last_fetched: e[:last_fetched], last_suggested: e[:last_suggested])
        [url, pr.association_score(now: now, usage: usage) * e[:relay].adjusted_score]
      end.sort_by { |_, s| -s }
    end

    def write_relays_for(pubkey)
      @db.execute(
        "SELECT url FROM person_relays WHERE pubkey = ? AND write = 1 " \
        "ORDER BY last_fetched DESC", [pubkey]
      ).map(&:first)
    end

    # Relays we associate with a person, most promising first: relays where
    # they say they write, then relays where we actually fetched their events
    # (both are where their kind 0 / kind 3 / 10002 will be found).
    def person_relay_urls(pubkey)
      @db.execute(
        "SELECT url FROM person_relays WHERE pubkey = ? " \
        "ORDER BY write DESC, last_fetched IS NULL, last_fetched DESC", [pubkey]
      ).map(&:first)
    end

    private

    def row_to_event(row)
      NostrCore::Event.new(id: row[0], pubkey: row[1], created_at: row[2],
                           kind: row[3], content: row[4], tags: JSON.parse(row[5]))
    end

    def row_to_relay(row)
      NostrCore::Relay.new(url: row[0], rank: row[1], success_count: row[2],
                           successes: row[3], connected: row[4] == 1)
    end
  end
end
