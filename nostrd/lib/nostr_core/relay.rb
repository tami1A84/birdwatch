# frozen_string_literal: true

module NostrCore
  # Canonical wire form of a relay URL: trimmed, no trailing slash.
  # The wild advertises "wss://x" and "wss://x/" interchangeably — one
  # canonical key keeps the pool, the evidence store and the picker from
  # dialing (and scoring) the same relay twice.
  def self.normalize_relay_url(url)
    url.to_s.strip.sub(%r{/+\z}, "")
  end

  # A relay we know about. Ported from gossip's relay3.rs.
  class Relay
    attr_reader :url, :rank, :success_count, :successes
    attr_writer :connected

    def initialize(url:, rank: 5, success_count: 0, successes: 0, connected: false)
      @url = url.to_s
      @rank = rank.clamp(1, 9)
      @success_count = success_count
      @successes = successes
      @connected = connected
    end

    def connected? = @connected

    def success_rate
      return 0.0 if success_count.zero?

      successes.to_f / success_count
    end

    # Pure quality score, 0.0..1.0. No penalty for low attempts:
    # new relays must be allowed to establish a track record.
    def score
      (rank / 9.0) * (0.5 + 0.5 * success_rate)
    end

    def adjusted_score(success_count_boost: false)
      s = score
      s /= 2.0 unless connected?
      s *= Math.log10(success_count) if success_count_boost
      s = 0.0 if success_count_boost && success_count.zero?
      s
    end

    def record_success(success:)
      @success_count += 1
      @successes += 1 if success
    end
  end
end
