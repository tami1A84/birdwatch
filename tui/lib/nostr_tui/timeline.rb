# frozen_string_literal: true

module NostrTui
  # In-memory timeline. The daemon's SQLite is the truth; this is a view cache.
  class Timeline
    Event = Struct.new(:id, :pubkey, :created_at, :kind, :content, :tags,
                       :author, :handle) do
      # Display name once a kind 0 profile is known, else the short pubkey.
      def author_short = author || pubkey[0, 8]

      def author_handle = handle
    end

    def initialize
      @by_id = {}
      @by_pubkey = Hash.new { |h, k| h[k] = [] } # author => events, for cheap relabeling
      @profiles = {}
      @reactions = Hash.new { |h, k| h[k] = {} } # target id => { author pubkey => content }
      @all_cache = nil
    end

    # The timeline view is notes only (kind 1); metadata (0) and relay lists
    # (10002) live in the daemon, never on screen. Kind 7 (NIP-25) is indexed
    # into per-note 👍 counts instead of shown as a note.
    def add_h(hash)
      return index_reaction(hash) if hash["kind"].to_i == 7
      return false unless [1, 1111].include?(hash["kind"].to_i) # notes + NIP-22 comments

      add(Event.new(hash["id"], hash["pubkey"], hash["created_at"].to_i,
                    hash["kind"].to_i, hash["content"].to_s, hash["tags"] || []))
    end

    def index_reaction(hash)
      target = (hash["tags"] || []).find { |t| t.is_a?(Array) && t[0] == "e" }&.[](1)
      return false unless target && hash["pubkey"]

      @reactions[target][hash["pubkey"]] = hash["content"].to_s
      true
    end

    # 👍 count on a note. The canonical like is "+"; other reaction contents
    # ("👍", emoji) still count — NIP-25 clients vary.
    def reaction_count(id)
      @reactions[id]&.size || 0
    end

    def liked_by_me?(id, me)
      return false unless me

      @reactions[id]&.key?(me)
    end

    def add(event)
      return false if @by_id.key?(event.id)

      @by_id[event.id] = event
      @by_pubkey[event.pubkey] << event
      decorate(event)
      @all_cache = nil
      true
    end

    # kind 0 snapshots from the daemon ("profiles" frames). At boot these
    # used to arrive one author per frame; redecorating EVERY event per
    # frame made startup O(events x frames) — seconds of frozen UI. Now:
    # identical snapshots are skipped and only the touched author's events
    # are relabeled.
    def apply_profiles(profiles)
      touched = []
      Array(profiles).each do |p|
        next unless p.is_a?(Hash) && p["pubkey"]

        pk = p["pubkey"]
        next if @profiles[pk] == p # unchanged snapshot — skip

        @profiles[pk] = p
        touched << pk
      end
      touched.each do |pk|
        @by_pubkey[pk].each { |e| decorate(e) }
      end
      @all_cache = nil unless touched.empty?
      touched
    end

    # Sorted newest-first, memoized: every keystroke repaint used to re-sort
    # the whole timeline (filter -> all). Mutators nil the cache.
    def all
      @all_cache ||= @by_id.values.sort_by { |e| -e.created_at }
    end

    def find(id) = @by_id[id]

    def profile_for(pubkey) = @profiles[pubkey]

    def count = @by_id.size

    # / incremental search over content, author label/handle and pubkey
    def filter(query)
      return all if query.nil? || query.empty?

      q = query.downcase
      all.select do |e|
        e.content.downcase.include?(q) || e.author_short.to_s.downcase.include?(q) ||
          e.author_handle.to_s.downcase.include?(q) || e.pubkey.include?(q)
      end
    end

    # http(s) URLs in the raw content (display wrapping never splits the raw
    # token). Trailing punctuation often glues onto a URL in prose
    # ("…/.jpg。") — trim it before handing the link to the browser.
    URL_TRAILING = %r{[.,;:!?、。！？）)〉》」』”’>]+\z}

    def links(event)
      event.content.scan(%r{https?://\S+}).map { |l| l.sub(URL_TRAILING, "") }.uniq
    end

    private

    def decorate(event)
      p = @profiles[event.pubkey] || {}
      event.author = blank(p["display_name"]) || blank(p["name"])
      event.handle = blank(p["nip05"])
    end

    def blank(v) = v.nil? || v.to_s.strip.empty? ? nil : v.to_s
  end
end
