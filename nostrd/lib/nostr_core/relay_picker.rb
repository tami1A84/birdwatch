# frozen_string_literal: true

module NostrCore
  # Port of gossip's RelayPicker (relay_picker.rs).
  #
  # Not "pick 3 relays once" but "keep every followed person covered by
  # num_relays_per_person relays, continuously". Assignment is a state machine:
  # scores decay, relays fail into a penalty box, and people get reassigned.
  class RelayPicker
    # Adapted from gossip's "top-3 or score > 5.0" floor rule (marked FIXME there).
    # Outside a person's top-3 relays, require a meaningful score.
    TOP3 = 3
    JUNK_FLOOR = 0.1

    def initialize(num_relays_per_person: 3, max_relays: 15, now: -> { Time.now.to_i })
      @num_relays_per_person = num_relays_per_person
      @max_relays = max_relays
      @now = now
      @person_scores = {} # pubkey => [[url, score], ...] sorted desc
      @assignments = {}   # url => [pubkey, ...]
      @excluded = {}      # url => assignable again after this unixtime
      @pubkey_counts = {} # pubkey => assignments still needed
    end

    attr_reader :assignments, :excluded, :pubkey_counts, :person_scores

    def add_someone(pubkey, person_relay_scores)
      scores = person_relay_scores.sort_by { |_, s| -s }
      @person_scores[pubkey] = scores
      @pubkey_counts[pubkey] ||= @num_relays_per_person
    end

    def remove_someone(pubkey)
      @person_scores.delete(pubkey)
      @pubkey_counts.delete(pubkey)
      @assignments.each_value { |pks| pks.delete(pubkey) }
      @assignments.delete_if { |_, pks| pks.empty? }
    end

    # A relay failed. Put it in the penalty box and return its people to the
    # seeking pool so the next picks reassign them elsewhere.
    def relay_disconnected(url, penalty_seconds)
      @excluded[url.to_s] = @now.call + penalty_seconds if penalty_seconds.positive?
      assigned = @assignments.delete(url.to_s)
      return unless assigned

      assigned.each { |pk| @pubkey_counts[pk] = (@pubkey_counts[pk] || 0) + 1 }
    end

    # One greedy step: sum the scores of still-uncovered people per relay,
    # hand the winning relay every person it covers. Returns the winning url.
    def pick
      prune_exclusions
      at_max = @assignments.size >= @max_relays

      scoreboard = Hash.new(0.0)
      @person_scores.each do |pubkey, relays|
        next if (@pubkey_counts[pubkey] || 0).zero?

        relays.each do |url, score|
          next if @excluded.key?(url)
          next if at_max && !@assignments.key?(url)
          next if @assignments[url]&.include?(pubkey)

          scoreboard[url] += score
        end
      end

      url, best = scoreboard.max_by { |_, s| s }
      return nil if url.nil? || best <= 1e-12

      covered = covered_pubkeys(url)
      return nil if covered.empty?

      covered.each { |pk| @pubkey_counts[pk] -= 1 if @pubkey_counts[pk].positive? }
      (@assignments[url] ||= []).concat(covered)
      url
    end

    # Pick until everyone is covered or no progress is possible.
    # Returns the relays that received assignments, in order.
    def pick_all
      picks = []
      while (url = pick)
        picks << url
      end
      picks
    end

    def garbage_collect(followed)
      followed = followed.map(&:to_s)
      @person_scores.keys.each do |pk|
        remove_someone(pk) unless followed.include?(pk)
      end
      @assignments.each_value { |pks| pks.reject! { |pk| !followed.include?(pk) } }
      idle = @assignments.select { |_, pks| pks.empty? }.keys
      idle.each { |url| @assignments.delete(url) }
      idle
    end

    private

    def prune_exclusions
      @excluded.delete_if { |_, until_t| until_t <= @now.call }
    end

    def covered_pubkeys(url)
      covered = []
      @person_scores.each do |pubkey, relays|
        next if (@pubkey_counts[pubkey] || 0).zero?
        next if @assignments[url]&.include?(pubkey)

        relays.each_with_index do |(relay_url, relay_score), i|
          next unless relay_url == url

          covered << pubkey if i < TOP3 || relay_score >= JUNK_FLOOR
          break
        end
      end
      covered
    end
  end
end
