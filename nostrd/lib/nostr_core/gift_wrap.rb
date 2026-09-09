# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require_relative "nip44"
require_relative "event"
require_relative "bip340"

module NostrCore
  # NIP-59 gift wrap (the NIP-17 private-DM transport): a kind-14 chat
  # rumor (unsigned) is sealed into kind 13 (NIP-44 to the recipient, signed
  # by the sender), then wrapped into kind 1059 (NIP-44 to the recipient
  # with a FRESH RANDOM key) — the outer event hides sender and recipient
  # from everyone but the holder of the recipient key.
  module GiftWrap
    KIND_RUMOR = 14
    KIND_SEAL = 13
    KIND_GIFT = 1059
    # NIP-59 §sealing: seal/wrap created_at are randomized over the last 2
    # days — a precise timestamp would leak when the message was written.
    JITTER_SECONDS = 2 * 24 * 60 * 60

    module_function

    # Unsealed chat message (NIP-17 §kind-14). It carries a computed id (ids
    # are derivable without signing) but never a sig — the store keys rows
    # on id, so our own rumor and the recipient's unwrapped copy land as
    # the same event.
    def chat_rumor(text, to:, from:, subject: nil)
      raise ArgumentError, "recipient pubkey must be 64 hex chars" unless hex64?(to)
      raise ArgumentError, "sender pubkey must be 64 hex chars" unless hex64?(from)

      tags = [["p", to]]
      tags << ["subject", subject] if subject && !subject.to_s.empty?
      rumor = { "pubkey" => from, "created_at" => Time.now.to_i, "kind" => KIND_RUMOR,
                "tags" => tags, "content" => text.to_s }
      rumor["id"] = compute_id(rumor)
      rumor
    end

    # Full NIP-59 wrap. Returns [seal_event, gift_wrap_event] (hashes with
    # id+sig). The seal is signed by the sender; the wrap by a throwaway
    # key drawn the same way the daemon's signer draws identities.
    def wrap(rumor:, sender_priv:, recipient_pub:)
      raise ArgumentError, "recipient pubkey must be 64 hex chars" unless hex64?(recipient_pub)
      raise ArgumentError, "sender secret key must be 32 bytes" unless
        sender_priv.is_a?(String) && sender_priv.bytesize == 32

      rumor = stringify(rumor)
      raise ArgumentError, "rumor must be a kind-14 event hash" unless
        rumor && rumor["kind"] == KIND_RUMOR

      seal = { "pubkey" => Bip340.public_key(sender_priv),
               "created_at" => jittered_now, "kind" => KIND_SEAL, "tags" => [],
               "content" => Nip44.encrypt(sender_priv, [recipient_pub].pack("H*"),
                                          JSON.generate(rumor)) }
      seal["id"] = compute_id(seal)
      seal["sig"] = sign_id(seal["id"], sender_priv)

      # Fresh random key per message: a reused wrap key would link the
      # sender's messages and let one key compromise decrypt older wraps.
      wrap_priv = fresh_seckey
      gift = { "pubkey" => Bip340.public_key(wrap_priv),
               "created_at" => jittered_now, "kind" => KIND_GIFT,
               "tags" => [["p", recipient_pub]],
               "content" => Nip44.encrypt(wrap_priv, [recipient_pub].pack("H*"),
                                          JSON.generate(seal)) }
      gift["id"] = compute_id(gift)
      gift["sig"] = sign_id(gift["id"], wrap_priv)
      [seal, gift]
    end

    # Recipient-side unwrap. Strict: structure (kinds, p-tag, hex pubkeys),
    # both NIP-44 MAC layers, the seal's BIP-340 signature, and any id/sig
    # the inner events carry. ANY failure → nil: garbage must never raise
    # into the relay/ingest thread.
    def unwrap(gift_wrap:, recipient_priv:)
      gift = stringify(gift_wrap)
      return nil unless gift && gift["kind"] == KIND_GIFT

      p_tag = Array(gift["tags"]).find { |t| t.is_a?(Array) && t[0] == "p" }
      return nil unless p_tag && hex64?(p_tag[1]) && hex64?(gift["pubkey"])

      # Layer 1: the wrap content is sealed from the EPHEMERAL wrap key to
      # the recipient — the conversation key uses the wrap's own pubkey,
      # not the p-tag (the p-tag only says who the wrap is addressed to).
      seal = parse_json(Nip44.decrypt(recipient_priv, [gift["pubkey"]].pack("H*"),
                                      gift["content"]))
      return nil unless seal.is_a?(Hash) && seal["kind"] == KIND_SEAL && hex64?(seal["pubkey"])
      return nil unless signature_ok?(seal)

      rumor = parse_json(Nip44.decrypt(recipient_priv, [seal["pubkey"]].pack("H*"), seal["content"]))
      return nil unless rumor.is_a?(Hash) && rumor["kind"] == KIND_RUMOR && hex64?(rumor["pubkey"])
      return nil unless signature_ok?(rumor)

      rumor
    rescue StandardError
      nil
    end

    # --- internals --------------------------------------------------------

    def jittered_now
      Time.now.to_i - rand(1..JITTER_SECONDS)
    end

    # Same recipe as Nostrd::Signer#create_key's fresh identity: 32 random
    # bytes, retried on the (probability-zero but cheap to check) case of a
    # scalar outside [1, N-1].
    def fresh_seckey
      loop do
        sk = SecureRandom.bytes(32)
        d = Bip340.to_int(sk)
        return sk if d.positive? && d < Bip340::N
      end
    end

    def sign_id(id_hex, seckey)
      Bip340.sign([id_hex].pack("H*"), seckey, SecureRandom.random_bytes(32)).unpack1("H*")
    end

    def compute_id(hash)
      Digest::SHA256.hexdigest(Event.id_payload(hash["pubkey"], hash["created_at"],
                                                hash["kind"], hash["tags"], hash["content"]))
    end

    # The seal MUST be signed (BIP-340 over its id); the rumor carries an id
    # but no sig, so a present id must simply match its own serialization.
    def signature_ok?(hash)
      id = hash["id"].to_s
      sig = hash["sig"].to_s
      if sig.match?(/\A[0-9a-f]{128}\z/)
        id.match?(/\A[0-9a-f]{64}\z/) && id == compute_id(hash) &&
          Bip340.verify([hash["pubkey"]].pack("H*"), [id].pack("H*"), [sig].pack("H*"))
      elsif sig.empty?
        id.empty? || id == compute_id(hash)
      else
        false
      end
    end

    # Symbol or string keys → canonical string-keyed hash; nil on garbage.
    def stringify(hash)
      return nil unless hash.is_a?(Hash)

      h = {}
      hash.each { |k, v| h[k.to_s] = v }
      h["kind"] = Integer(h["kind"])
      h["created_at"] = Integer(h["created_at"])
      h["content"] = h["content"].to_s
      h["tags"] = Array(h["tags"]).map { |t| Array(t).map(&:to_s) }
      h
    rescue StandardError
      nil
    end

    def parse_json(str)
      JSON.parse(str)
    rescue JSON::ParserError, TypeError
      nil
    end

    def hex64?(s) = s.is_a?(String) && s.match?(/\A[0-9a-f]{64}\z/)
  end
end
