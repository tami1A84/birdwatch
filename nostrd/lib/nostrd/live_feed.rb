# frozen_string_literal: true

module Nostrd
  # Live home feed gate between event sources and the socket server.
  # Two source shapes arrive here: events we signed ourselves (symbol keys,
  # from the publisher's self-echo) and relay JSON (string keys, via
  # on_event). LiveFeed normalizes both to string keys, keeps only the
  # home-feed kinds (1 notes, 1111 NIP-22 comments), and remembers recent
  # ids so the relay echo of an event we already sent is not re-broadcast.
  #
  # fresh: an optional "is this id new to the store?" gate. Relays replay
  # days of stored history on every (re)connect (home REQ carries no since,
  # deliberately, to backfill gaps); without the gate every replay was
  # broadcast to clients, whose per-event profile push then re-decorated
  # the whole timeline — the TUI froze for seconds right after startup.
  # Own publishes pass with force: (they are stored before the push, but
  # the user must see them the moment they post).
  # push(fresh:) lets the wiring pass a PRE-computed answer: the normal
  # call site ingests (stores) the event BEFORE pushing, so a post-ingest
  # gate check would classify every relay arrival as replay and swallow
  # all live updates — the TUI timeline stopped refreshing (2026-09-10).
  class LiveFeed
    KINDS = [1, 7, 1111].freeze
    MAX_SEEN = 500

    def initialize(fresh: nil, &sink)
      @fresh = fresh
      @sink = sink
      @seen = {}
    end

    def push(ev, force: false, fresh: nil)
      return unless ev.is_a?(Hash)

      ev = ev.transform_keys(&:to_s)
      return unless KINDS.include?(ev["kind"]) && ev["id"]
      # nil = no override: fall back to the constructor gate (or allow).
      is_fresh = fresh.nil? ? (@fresh ? @fresh.call(ev["id"]) : true) : fresh
      return if !force && !is_fresh
      return if @seen.delete(ev["id"]) # already sent to clients

      @seen[ev["id"]] = true
      @seen.shift if @seen.size > MAX_SEEN
      @sink.call(ev)
    end
  end
end
