# frozen_string_literal: true

require "json"
require "digest"
require "securerandom"
require_relative "../nostr_core/event"
require_relative "../nostr_core/vault"
require_relative "../nostr_core/bip340"

module Nostrd
  # The vault signs actions, never raw events from clients. Holds the nsec
  # encrypted at rest (NIP-49 intent via NostrCore::Vault).
  class Signer
    def initialize(vault_path: nil)
      @vault_path = vault_path
      @seckey = nil
      @pubkey = nil
    end

    attr_reader :pubkey

    def locked? = @seckey.nil?

    def create_key(passphrase:, seckey_hex: nil, logn: 16)
      created = NostrCore::Vault.create(passphrase: passphrase, seckey_hex: seckey_hex)
      File.write(@vault_path, created[:blob]) if @vault_path
      File.chmod(0600, @vault_path) if @vault_path # never world-readable
      unlock_with(created[:blob], passphrase)
    end

    def unlock(passphrase)
      raise ArgumentError, "no vault at #{@vault_path}" unless @vault_path && File.exist?(@vault_path)

      unlock_with(File.read(@vault_path).strip, passphrase)
    end

    def lock
      @seckey = nil
      @pubkey = nil
    end

    # Rewrite the vault in official NIP-49 format (ncryptsec). Used by
    # --upgrade-vault to migrate legacy NVAULT1 files in place.
    def resave(passphrase, logn: 16)
      raise "signer is locked" if locked?

      blob = NostrCore::Vault.encrypt(passphrase, @seckey.unpack1("H*"), logn: logn)
      File.write(@vault_path, blob)
      File.chmod(0600, @vault_path) if @vault_path
      blob
    end

    # Action boundary: clients send intent, the daemon signs.
    # Returns the signed event hash.
    def call(name, params)
      raise "signer is locked" if locked?

      case name
      when "post_note"
        raise ArgumentError, "post_note needs text" if params["text"].to_s.empty?

        sign_event(1, params["text"], params["tags"] || [])
      when "post_comment"
        # NIP-22 comment (kind 1111): uppercase tags point at the root scope,
        # lowercase at the direct parent. A reply to a kind 1 note is its own
        # root; a reply to a comment inherits that comment's root tags.
        text = params["text"].to_s
        parent = params["parent"].is_a?(Hash) ? params["parent"] : {}
        pid = parent["id"].to_s
        ppk = parent["pubkey"].to_s
        pkind = parent["kind"].to_i
        raise ArgumentError, "post_comment needs text and parent {id:, pubkey:, kind:}" if
          text.empty? || pid.size != 64 || ppk.size != 64

        pt = parent["tags"].is_a?(Array) ? parent["tags"] : []
        root_id = (pt.find { |t| t.is_a?(Array) && t[0] == "E" } || [nil, pid])[1]
        root_pk = (pt.find { |t| t.is_a?(Array) && t[0] == "P" } || [nil, ppk])[1]
        root_kind = (pt.find { |t| t.is_a?(Array) && t[0] == "K" } || [nil, pkind.to_s])[1]
        tags = [["E", root_id], ["K", root_kind.to_s], ["P", root_pk],
                ["e", pid], ["k", pkind.to_s], ["p", ppk]]
        sign_event(1111, text, tags)
      when "like"
        # NIP-25 reaction (kind 7): "+" is the canonical like content.
        # e/p tags point at the reacted note and its author (NIP-25 §kind-7).
        rid = params["id"].to_s
        rpk = params["pubkey"].to_s
        raise ArgumentError, "like needs id and pubkey" if rid.size != 64 || rpk.size != 64

        sign_event(7, "+", [["e", rid], ["p", rpk]])
      when "update_profile"
        # NIP-01 profile metadata (kind 0): whitelist the known fields,
        # drop empties, and sign the JSON content with no tags.
        p = params["profile"]
        raise ArgumentError, "profile must be an object" unless p.is_a?(Hash)

        allowed = %w[name display_name about picture nip05 banner website]
        content = allowed.filter_map { |k| v = p[k].to_s; [k, v] unless v.empty? }.to_h
        raise ArgumentError, "profile is empty" if content.empty?

        sign_event(0, JSON.generate(content), [])
      when "update_relay_list"
        tags = params["relays"].to_a.filter_map do |r|
          next unless r.is_a?(Hash) && r["url"].to_s.start_with?("ws")

          # NIP-65 canonical form: ["r", url] = read+write; ["r", url, "w"|"r"] narrows it.
          r["marker"] ? ["r", r["url"], r["marker"]] : ["r", r["url"]]
        end
        raise ArgumentError, "update_relay_list needs relays [{url:, marker:}]" if tags.empty?

        sign_event(10002, "", tags)
      when "get_public_key"
        @pubkey
      else
        raise ArgumentError, "unknown action #{name}"
      end
    end

    # NIP-42 auth response (kind 22242): relay + challenge tags, empty body.
    def auth_event(challenge, relay_url)
      raise "signer is locked" if locked?

      sign_event(22242, "", [["relay", relay_url], ["challenge", challenge]])
    end

    def sign_event(kind, content, tags = [], created_at: Time.now.to_i)
      event = { pubkey: @pubkey, created_at: created_at, kind: kind, tags: tags, content: content }
      payload = NostrCore::Event.id_payload(event[:pubkey], created_at, kind, tags, content)
      id = Digest::SHA256.hexdigest(payload)
      sig = NostrCore::Bip340.sign([id].pack("H*"), @seckey, SecureRandom.random_bytes(32))
      event.merge(id: id, sig: sig.unpack1("H*"))
    end

    private

    def unlock_with(blob, passphrase)
      @seckey = [NostrCore::Vault.unlock(passphrase, blob)].pack("H*")
      @pubkey = NostrCore::Bip340.public_key(@seckey)
      true
    end
  end
end
