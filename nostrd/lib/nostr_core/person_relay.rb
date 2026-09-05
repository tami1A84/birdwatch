# frozen_string_literal: true

require_relative "decay"

module NostrCore
  # Evidence tying one person to one relay. Ported from gossip's person_relay2.rs.
  class PersonRelay
    attr_reader :url, :write, :read, :last_fetched, :last_suggested

    def initialize(url:, write: false, read: false, last_fetched: nil, last_suggested: nil)
      @url = url.to_s
      @write = write
      @read = read
      @last_fetched = last_fetched
      @last_suggested = last_suggested
    end

    # Author-signed NIP-65 claims count fully; empirical evidence decays.
    # usage: :outbox (timeline) or :inbox (mentions/DM detection).
    def association_score(now:, usage: :outbox)
      score = 0.0
      score += 1.0 if usage == :outbox && write
      score += 1.0 if usage == :inbox && read

      if last_fetched
        score += Decay.exponential(0.2, FOURTEEN_DAYS, now - last_fetched)
      end
      if last_suggested
        score += Decay.exponential(0.1, SEVEN_DAYS, now - last_suggested)
      end
      score
    end

    FOURTEEN_DAYS = 14 * 24 * 60 * 60
    SEVEN_DAYS = 7 * 24 * 60 * 60
    private_constant :FOURTEEN_DAYS, :SEVEN_DAYS
  end
end
