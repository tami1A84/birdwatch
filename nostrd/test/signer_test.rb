# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/nostrd/signer"
require_relative "../lib/nostrd/nip46"

class SignerTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "vault.bin")
    @signer = Nostrd::Signer.new(vault_path: @path)
  end

  def test_create_unlock_and_real_signing

    @signer.create_key(passphrase: "opensesame")
    assert_equal 64, @signer.pubkey.size

    @signer.lock
    assert_predicate @signer, :locked?
    @signer.unlock("opensesame")
    refute_predicate @signer, :locked?

    event = @signer.call("post_note", { "text" => "hello nostr" })
    assert_equal 1, event[:kind]
    assert_equal @signer.pubkey, event[:pubkey]
    assert_equal 64, event[:id].size
    assert_equal 128, event[:sig].size

    # independent check: the signature must satisfy our own BIP-340 verify
    require_relative "../lib/nostr_core/bip340"
    assert NostrCore::Bip340.verify([@signer.pubkey].pack("H*"), [event[:id]].pack("H*"),
                                    [event[:sig]].pack("H*"))
  end

  # NIP-22 kind 1111: reply-to-note is its own root; reply-to-comment
  # inherits the parent's uppercase root tags.
  def test_post_comment_builds_nip22_tags
    @signer.create_key(passphrase: "opensesame")
    note = { "id" => "aa" * 32, "pubkey" => "bb" * 32, "kind" => 1 }
    ev = @signer.call("post_comment", { "text" => "hi", "parent" => note })
    assert_equal 1111, ev[:kind]
    assert_equal [["E", "aa" * 32], ["K", "1"], ["P", "bb" * 32],
                  ["e", "aa" * 32], ["k", "1"], ["p", "bb" * 32]], ev[:tags]

    comment = { "id" => "ee" * 32, "pubkey" => "ff" * 32, "kind" => 1111,
                "tags" => [["E", "cc" * 32], ["K", "1"], ["P", "dd" * 32],
                           ["e", "ee" * 32], ["k", "1111"], ["p", "ff" * 32]] }
    ev2 = @signer.call("post_comment", { "text" => "nested", "parent" => comment })
    assert_equal [["E", "cc" * 32], ["K", "1"], ["P", "dd" * 32],
                  ["e", "ee" * 32], ["k", "1111"], ["p", "ff" * 32]], ev2[:tags]
    assert_raises(ArgumentError) { @signer.call("post_comment", { "text" => "x", "parent" => {} }) }
  end

  def test_like_signs_nip25_kind7
    @signer.create_key(passphrase: "opensesame")
    ev = @signer.call("like", { "id" => "aa" * 32, "pubkey" => "bb" * 32 })
    assert_equal 7, ev[:kind]
    assert_equal "+", ev[:content]
    assert_equal [["e", "aa" * 32], ["p", "bb" * 32]], ev[:tags]
    assert_raises(ArgumentError) { @signer.call("like", { "id" => "short", "pubkey" => "bb" * 32 }) }
  end

  # NIP-42: the auth response is a signed kind 22242 with relay+challenge.
  def test_update_profile_signs_nip01_kind0
    @signer.create_key(passphrase: "opensesame")
    ev = @signer.call("update_profile", { "profile" => { "name" => "ロクヨウ",
                                                         "about" => "TUI enjoyer",
                                                         "nip05" => "" } })
    assert_equal 0, ev[:kind]
    assert_equal '{"name":"ロクヨウ","about":"TUI enjoyer"}', ev[:content]
    assert_empty ev[:tags]
    assert_raises(ArgumentError) { @signer.call("update_profile", { "profile" => {} }) }
    assert_raises(ArgumentError) { @signer.call("update_profile", { "profile" => "x" }) }
  end

  def test_auth_event_signs_kind22242
    @signer.create_key(passphrase: "opensesame")
    ev = @signer.auth_event("ch1", "wss://pay.relay")
    assert_equal 22242, ev[:kind]
    assert_equal "", ev[:content]
    assert_equal [["relay", "wss://pay.relay"], ["challenge", "ch1"]], ev[:tags]
  end

  def test_locked_signer_refuses_actions
    @signer.create_key(passphrase: "pw")
    @signer.lock
    assert_raises(RuntimeError) { @signer.call("post_note", { "text" => "x" }) }
  end

  def test_wrong_passphrase_is_rejected
    @signer.create_key(passphrase: "pw")
    @signer.lock
    assert_raises(ArgumentError) { @signer.unlock("nope") }
  end

  def test_nip46_handler_signs_via_vault
    @signer.create_key(passphrase: "pw")
    handler = Nostrd::Nip46Handler.new(@signer)

    pong = handler.handle({ "id" => "1", "method" => "ping" })
    assert_equal "pong", pong[:result]

    # signing requires a (v0: trivial) connect handshake first
    connect = handler.handle({ "id" => "1b", "method": "connect" }.transform_keys(&:to_s))
    assert_equal "connect confirmed", connect[:result]

    pk = handler.handle({ "id" => "2", "method" => "get_public_key" })
    assert_equal @signer.pubkey, pk[:result]

    req = { "id" => "3", "method" => "sign_event",
            "params" => { "kind" => 1, "content" => "via nip46", "tags" => [] } }
    signed = handler.handle(req)
    assert_equal @signer.pubkey, signed[:result]["pubkey"]
    assert signed[:result]["sig"]

    unknown = handler.handle({ "id" => "4", "method" => "nope" })
    assert_equal -32601, unknown[:error][:code]
  end

  def test_update_relay_list_builds_kind_10002
    @signer.create_key(passphrase: "pw")
    ev = @signer.call("update_relay_list",
                      "relays" => [{ "url" => "wss://x", "marker" => "w" },
                                   { "url" => "wss://y", "marker" => "r" },
                                   { "url" => "bad" }])
    assert_equal 10002, ev[:kind]
    assert_equal [["r", "wss://x", "w"], ["r", "wss://y", "r"]], ev[:tags]
  end

  def test_nip01_event_id_matches_real_relay_event
    # Golden vector: a real event fetched from wss://nos.lol during the
    # 2026-09-04 live run (author 947e8ec3..., a 🙏 reaction note).
    tags = [
      ["e", "2c2857928cba35244b888923682c1c11da124e731f5c2c951cbb1f23dd029dd8", "", "root"],
      ["e", "6de87b731656c022d1b1bb72aa71a57944a303ca1bebd0c08d586a5f12f03c6a", "", "reply"],
      ["p", "f27341f6cf1e7abdf894372246332f58fe79c9925d489fe597218017314adfd3"],
      ["p", "947e8ec354d9565543e0d39676866cce3f3aadb074dcf36ef82642e5ad1dffc2"]
    ]
    payload = NostrCore::Event.id_payload(
      "947e8ec354d9565543e0d39676866cce3f3aadb074dcf36ef82642e5ad1dffc2",
      1_788_282_706, 1, tags, "🙏"
    )
    assert_equal "60990be675d2611c6672637ec872e933b87a413ad50d3c1d8440edc91e47bb8c",
                 Digest::SHA256.hexdigest(payload)
  end
end
