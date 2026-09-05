# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_core/bip340"
require_relative "../lib/nostr_core/vault"

class CryptoTest < Minitest::Test
  def test_bip340_official_vector_0
    sk = "00" * 31 + "03"
    msg = "00" * 32
    aux = "00" * 32
    sig = NostrCore::Bip340.sign([msg].pack("H*"), [sk].pack("H*"), [aux].pack("H*"))
    pk = NostrCore::Bip340.to_bytes(0xF9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9, 32)
    expected = ["E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215" \
                "25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0"].pack("H*")
    assert_equal expected, sig
    assert NostrCore::Bip340.verify(pk, [msg].pack("H*"), sig)
  end

  def test_bip340_sign_verify_roundtrip
    sk = SecureRandom.random_bytes(32)
    msg = SecureRandom.random_bytes(32)
    aux = SecureRandom.random_bytes(32)
    pk = [NostrCore::Bip340.public_key(sk)].pack("H*")
    sig = NostrCore::Bip340.sign(msg, sk, aux)
    assert NostrCore::Bip340.verify(pk, msg, sig)
    bad_msg = SecureRandom.random_bytes(32)
    refute NostrCore::Bip340.verify(pk, bad_msg, sig)
  end

  def test_vault_roundtrip_and_wrong_passphrase
    created = NostrCore::Vault.create(passphrase: "correct horse", seckey_hex: "ab" * 32)
    assert_equal 64, created[:pubkey_hex].size
    sk = NostrCore::Vault.unlock("correct horse", created[:blob])
    assert_equal "ab" * 32, sk
    assert_raises(ArgumentError) { NostrCore::Vault.unlock("wrong", created[:blob]) }
  end
end
