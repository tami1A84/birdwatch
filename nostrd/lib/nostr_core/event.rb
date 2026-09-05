# frozen_string_literal: true

module NostrCore
  # Minimal value object for a kind-1 style event.
  class Event
    attr_reader :id, :pubkey, :created_at, :kind, :content, :tags

    def initialize(id:, pubkey:, created_at:, kind: 1, content: "", tags: [])
      @id = id
      @pubkey = pubkey
      @created_at = Integer(created_at)
      @kind = kind
      @content = content.to_s
      @tags = tags
    end

    def to_h
      { id: id, pubkey: pubkey, created_at: created_at,
        kind: kind, content: content, tags: tags }
    end

    def self.from_h(h)
      new(id: h["id"] || h[:id], pubkey: h["pubkey"] || h[:pubkey],
          created_at: h["created_at"] || h[:created_at],
          kind: h["kind"] || h[:kind] || 1,
          content: h["content"] || h[:content] || "",
          tags: h["tags"] || h[:tags] || [])
    end

    # NIP-01 serialization that event ids are computed over:
    # sha256([0, pubkey, created_at, kind, tags, content]).
    # The leading 0 is the NUMBER zero, not the string "0" — verified against
    # real relay events (docs/live-run-2026-09-04.md).
    def self.id_payload(pubkey, created_at, kind, tags, content)
      JSON.generate([0, pubkey, created_at, kind, tags, content])
    end
  end
end
