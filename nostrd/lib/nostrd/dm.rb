# frozen_string_literal: true

require "json"
require "sqlite3"
require_relative "../nostr_core/gift_wrap"
require_relative "../nostr_core/event"

module Nostrd
  # NIP-17 private-DM service, daemon side. Sending: build the kind-14
  # rumor, hand it to the sign+publish path (daemon signer + pool restricted
  # to the recipient's inbox relays ONLY, per NIP-17), and store our own
  # rumor so the chat history includes what we sent — the relay echo never
  # comes back to us (gift wraps are p-tagged to the recipient, so our inbox
  # sub never sees our own sends). Receiving: unwrap kind-1059 arrivals and
  # upsert the inner rumor into the shared store so dms/timeline see it.
  class Dm
    def initialize(store:, socket_db_path:, my_pubkey:, sign_and_publish: nil,
                   inbox_relays_for: nil, seckey: nil, logger: $stderr)
      @store = store
      @db_path = socket_db_path.to_s
      @my_pubkey = my_pubkey
      # ->(rumor, recipient_pub, relay_urls) => {"seal"=>.., "gift"=>..,
      # "published_to"=>[urls]} — signs the NIP-59 layers via the daemon
      # signer and publishes through the pool restricted to relay_urls
      # (wired at boot like the bunker/publisher paths).
      @sign_and_publish = sign_and_publish
      # ->(pubkey) => [relay urls] — the person's NIP-65 inbox evidence
      # (Orchestrator#inbox_relays_for / Store#best_relays_for usage: :inbox).
      @inbox_relays_for = inbox_relays_for
      # Raw 32-byte seckey for IN-PROCESS unwrap only (same rule as the
      # bunker transport's key use). nil = locked: nothing decrypts.
      @seckey = seckey
      @logger = logger
    end

    # Wrap + publish to the recipient's inbox relays, then store our rumor.
    # Returns {"event_id" =>, "published_to" => n} for the socket ack.
    def send_dm(text, to:)
      raise ArgumentError, "recipient pubkey must be 64 hex chars" unless
        to.is_a?(String) && to.match?(/\A[0-9a-f]{64}\z/)
      raise ArgumentError, "message text is empty" if text.to_s.empty?
      raise ArgumentError, "dm service is not wired for sending" unless @sign_and_publish

      rumor = NostrCore::GiftWrap.chat_rumor(text, to: to, from: @my_pubkey)
      relays = @inbox_relays_for ? Array(@inbox_relays_for.call(to)) : []
      out = @sign_and_publish.call(rumor, to, relays) || {}
      @store.upsert_event(NostrCore::Event.from_h(rumor))
      { "event_id" => rumor["id"], "published_to" => Array(out["published_to"]).size }
    end

    # Inbound kind 1059 (called by the orchestrator's ingest): unwrap for us
    # and upsert the inner kind-14 rumor so the thread sees it. Returns the
    # rumor or nil — never raises into the relay thread.
    def handle_gift_wrap(event, url)
      return nil unless event.is_a?(Hash) && event["kind"] == NostrCore::GiftWrap::KIND_GIFT
      return nil unless @seckey # locked signer: nothing to decrypt with

      p_tag = Array(event["tags"]).find { |t| t.is_a?(Array) && t[0] == "p" }
      return nil unless p_tag && p_tag[1] == @my_pubkey

      rumor = NostrCore::GiftWrap.unwrap(gift_wrap: event, recipient_priv: @seckey)
      return nil unless rumor # foreign/tampered/garbage wrap

      @store.upsert_event(NostrCore::Event.from_h(rumor))
      rumor
    rescue StandardError => e
      @logger.puts "dm: gift wrap via #{url} dropped: #{e.class}: #{e.message}"
      nil
    end

    # Chat history read straight from the events store (kind 14 rows: ours
    # from send_dm, theirs unwrapped on arrival). partner given → one thread
    # ({"events" => [...]}, newest first like the timeline); nil →
    # conversation list ({"conversations" => [{pubkey, last, count}]}).
    # Queries run on a SEPARATE read-only SQLite connection to the daemon db
    # — the shared Store stays the single writer (:memory: dev stores read
    # through it, a second connection to a memory db would be empty). Never
    # raises: bad params / db hiccups degrade to empty results.
    def dms(partner: nil, limit: 50)
      limit = (limit || 50).to_i.clamp(1, 200)
      partner = partner.to_s
      return { "events" => [], "conversations" => [] } unless
        partner.empty? || partner.match?(/\A[0-9a-f]{64}\z/)

      rumors = rumor_hashes(read_rows(limit * 20))
      if partner.empty?
        { "conversations" => conversations(rumors, limit) }
      else
        { "events" => rumors.select { |r| thread?(r, partner) }.first(limit) }
      end
    rescue StandardError => e
      @logger.puts "dm: dms query failed: #{e.class}: #{e.message}"
      { "events" => [], "conversations" => [] }
    end

    private

    def read_rows(cap)
      if @db_path == ":memory:"
        @store.timeline(limit: cap, kind: 14).map do |e|
          [e.id, e.pubkey, e.created_at, e.kind, e.content, JSON.generate(e.tags)]
        end
      else
        db = SQLite3::Database.new(@db_path, readonly: true)
        db.results_as_hash = false
        db.execute(
          "SELECT id, pubkey, created_at, kind, content, tags FROM events " \
          "WHERE kind = 14 ORDER BY created_at DESC LIMIT ?", [cap]
        )
      end
    end

    def rumor_hashes(rows)
      rows.filter_map do |id, pubkey, created_at, kind, content, tags_json|
        next unless kind == 14
        next unless (tags = parse_tags(tags_json))

        { "id" => id, "pubkey" => pubkey, "created_at" => created_at,
          "kind" => kind, "content" => content.to_s, "tags" => tags }
      end
    end

    def parse_tags(json)
      JSON.parse(json)
    rescue JSON::ParserError, TypeError
      nil
    end

    # 1:1 thread: the partner wrote it to us, or we wrote it to them.
    def thread?(rumor, partner)
      pks = p_tagged(rumor)
      (rumor["pubkey"] == partner && pks.include?(@my_pubkey)) ||
        (rumor["pubkey"] == @my_pubkey && pks.include?(partner))
    end

    # One row per partner: newest message + count (approximate — the scan is
    # capped), newest conversation first.
    def conversations(rumors, limit)
      convos = {}
      rumors.each do |r|
        other = conversation_partner(r)
        next unless other

        c = (convos[other] ||= { "pubkey" => other, "last" => r, "count" => 0 })
        c["count"] += 1
        c["last"] = r if r["created_at"] > c["last"]["created_at"]
      end
      convos.values.sort_by { |c| -c["last"]["created_at"] }.first(limit)
    end

    def conversation_partner(rumor)
      pks = p_tagged(rumor)
      if rumor["pubkey"] == @my_pubkey
        pks.find { |pk| pk != @my_pubkey }
      elsif pks.include?(@my_pubkey)
        rumor["pubkey"]
      end
    end

    def p_tagged(rumor)
      rumor["tags"].filter_map { |t| t[1] if t.is_a?(Array) && t[0] == "p" }
    end
  end
end
