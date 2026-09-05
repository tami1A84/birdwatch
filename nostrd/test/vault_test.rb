# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_core/vault"

class VaultTest < Minitest::Test
  # Official NIP-49 test vector (nips/49.md): decrypt with password 'nostr'.
  VECTOR = "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m" \
           "0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zx" \
           "fmu5gv8th8wclt0h4p"
  VECTOR_SECKEY = "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683"

  def test_nip49_official_test_vector_decrypts
    assert_equal VECTOR_SECKEY, NostrCore::Vault.decrypt("nostr", VECTOR)
  end

  def test_nip49_roundtrip_and_format
    blob = NostrCore::Vault.encrypt("ÅΩẛ̣ p@ss", VECTOR_SECKEY, logn: 16)
    assert blob.start_with?("ncryptsec1"), "HRP must be ncryptsec"
    hrp, words = NostrCore::Bech32.decode(blob)
    assert_equal "ncryptsec", hrp
    assert_equal 91, words.size * 5 / 8 # spec: 91 bytes before bech32
    assert_equal VECTOR_SECKEY, NostrCore::Vault.decrypt("ÅΩẛ̣ p@ss", blob)
  end

  def test_wrong_passphrase_and_tamper_are_rejected
    assert_raises(ArgumentError) { NostrCore::Vault.decrypt("wrong", VECTOR) }
    assert_raises(ArgumentError) { NostrCore::Vault.decrypt("nostr", VECTOR.sub(/.{4}\z/, "aaaa")) }
  end

  def test_legacy_nvault1_still_unlocks
    salt = "S" * 16
    nonce = "N" * 16
    key = OpenSSL::KDF.scrypt("old-pass", salt: salt, N: 2**8, r: 8, p: 1, length: 32)
    cipher = OpenSSL::Cipher.new("aes-256-cbc").encrypt
    cipher.key = key
    cipher.iv = nonce
    ct = cipher.update(["11" * 32].pack("H*")) + cipher.final
    blob = [NostrCore::Vault::MAGIC, 8].pack("a*C") + salt + nonce + ct
    assert_equal "11" * 32, NostrCore::Vault.unlock("old-pass", [blob].pack("m0"))
  end

  def test_create_uses_nip49_and_pubkey_matches
    created = NostrCore::Vault.create(passphrase: "x", seckey_hex: VECTOR_SECKEY)
    assert created[:blob].start_with?("ncryptsec1")
    assert_equal VECTOR_SECKEY, NostrCore::Vault.decrypt("x", created[:blob])
  end
end
