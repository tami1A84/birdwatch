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
    # Raw 32-byte seckey for IN-PROCESS crypto only: the bunker transport
    # derives NIP-44 conversation keys to encrypt/decrypt kind-24133 traffic.
    # Never sent over the socket protocol, never logged.
    attr_reader :seckey

    def locked? = @seckey.nil?

    def create_key(passphrase:, seckey_hex: nil, logn: 16)
      # No key given = generate a fresh identity (first-run flow).
      seckey_hex ||= SecureRandom.bytes(32).unpack1("H*")
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
      when "update_contacts"
        # NIP-01 kind 3 contact list: one p-tag per followed pubkey. The
        # caller (follow/unfollow op) passes the post-change follow set.
        pubkeys = params["pubkeys"].to_a.map(&:to_s).select do |pk|
          pk.match?(/\A[0-9a-f]{64}\z/)
        end
        sign_event(3, "", pubkeys.map { |pk| ["p", pk] })
      when "delete_note"
        # NIP-09 deletion (kind 5): one e-tag per deleted event plus a k-tag
        # for its kind. Targets [{id:, kind:}] are resolved by the caller.
        targets = params["targets"].to_a.filter_map do |t|
          id = t["id"].to_s
          id.match?(/\A[0-9a-f]{64}\z/) ? [id, t["kind"].to_s] : nil
        end
        raise ArgumentError, "delete_note needs targets [{id:, kind:}]" if targets.empty?

        tags = targets.flat_map { |(id, kind)| [["e", id], ["k", kind]] }
        sign_event(5, "", tags)
      when "announce_repo"
        # NIP-34 repo announcement (kind 30617) — what Buzz Desktop's Projects
        # view renders. Tag layout mirrors buzz-sdk build_repo_announcement
        # (d / name / description / clone / web / relays, empty content).
        repo_id = params["repo_id"].to_s
        raise ArgumentError, "repo_id must be [a-zA-Z0-9._-]{1,64}" unless
          repo_id.match?(/\A[a-zA-Z0-9._-]{1,64}\z/)

        name = params["name"].to_s
        raise ArgumentError, "name exceeds 128 chars" if name.length > 128

        desc = params["description"].to_s
        raise ArgumentError, "description exceeds 1024 chars" if desc.length > 1024

        clones = params["clone_urls"].to_a.map(&:to_s)
        raise ArgumentError, "clone_urls needs 1..5 urls" if clones.empty? || clones.size > 5
        raise ArgumentError, "clone_url must not be empty" if clones.any?(&:empty?)

        web = params["web_url"].to_s
        raise ArgumentError, "web_url exceeds 512 chars" if web.length > 512

        relays = params["relays"].to_a.map(&:to_s)
        raise ArgumentError, "too many relays (max 10)" if relays.size > 10
        relays.each do |r|
          raise ArgumentError, "relay must start with ws:// or wss://" unless r.start_with?("ws://", "wss://")
        end

        tags = [["d", repo_id]]
        tags << ["name", name] unless name.empty?
        tags << ["description", desc] unless desc.empty?
        tags << (["clone"] + clones)
        tags << ["web", web] unless web.empty?
        tags << (["relays"] + relays) unless relays.empty?
        sign_event(30617, "", tags)
      when "get_public_key"
        @pubkey
      when "sign_raw"
        sign_raw(params)
      else
        raise ArgumentError, "unknown action #{name}"
      end
    end

    # Vetted raw-signing for local tools. The default boundary is intent
    # actions only ("never raw events from clients"); these kinds are the
    # minimum exceptions local flows need and carry no free-form user
    # content: NIP-98 http auth (Blossom uploads), the user's Blossom server
    # list (kind 10063), and NIP-5A nsite manifests/snapshots. Everything
    # else stays refused.
    RAW_SIGN_KINDS = [27235, 10063, 15128, 35128, 5128].freeze
    RAW_SIGN_MAX_CONTENT = 64 * 1024

    def sign_raw(params)
      kind = params["kind"]
      unless RAW_SIGN_KINDS.include?(kind)
        raise ArgumentError, "kind #{kind.inspect} is not raw-signable"
      end

      tags = params["tags"]
      unless tags.is_a?(Array) && tags.all? { |t| t.is_a?(Array) && t.all?(String) }
        raise ArgumentError, "tags must be an array of string arrays"
      end

      content = params["content"]
      raise ArgumentError, "content must be a string" unless content.is_a?(String)
      raise ArgumentError, "content too large" if content.bytesize > RAW_SIGN_MAX_CONTENT

      created_at = params["created_at"] || Time.now.to_i
      raise ArgumentError, "created_at must be an integer" unless created_at.is_a?(Integer)

      sign_event(kind, content, tags, created_at: created_at)
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
