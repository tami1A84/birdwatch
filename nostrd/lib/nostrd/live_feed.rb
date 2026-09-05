# frozen_string_literal: true

module Nostrd
  # Live home feed gate between event sources and the socket server.
  # Two source shapes arrive here: events we signed ourselves (symbol keys,
  # from the publisher's self-echo) and relay JSON (string keys, via
  # on_event). LiveFeed normalizes both to string keys, keeps only the
  # home-feed kinds (1 notes, 1111 NIP-22 comments), and remembers recent
  # ids so the relay echo of an event we already sent is not re-broadcast.
  class LiveFeed
    KINDS = [1, 7, 1111].freeze
    MAX_SEEN = 500

    def initialize(&sink)
      @sink = sink
      @seen = {}
    end

    def push(ev)
      return unless ev.is_a?(Hash)

      ev = ev.transform_keys(&:to_s)
      return unless KINDS.include?(ev["kind"]) && ev["id"]
      return if @seen.delete(ev["id"]) # already sent to clients

      @seen[ev["id"]] = true
      @seen.shift if @seen.size > MAX_SEEN
      @sink.call(ev)
    end
  end
end
