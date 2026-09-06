# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "digest"
require_relative "../lib/nostr_core/nip44"
require_relative "../lib/nostr_core/bip340"

# NIP-44 v2 against the normative vectors (.scratch/specs/nip44-v2.json).
# The file's structure is {v2: {valid: {get_conversation_key, get_message_keys,
# calc_padded_len, encrypt_decrypt, encrypt_decrypt_long_msg},
# invalid: {encrypt_msg_lengths, get_conversation_key, decrypt}}}.
class Nip44Test < Minitest::Test
  VECTORS = JSON.parse(File.read(File.expand_path("../../.scratch/specs/nip44-v2.json", __dir__))).fetch("v2")

  def pub_of(sec_hex)
    [NostrCore::Bip340.public_key([sec_hex].pack("H*"))].pack("H*")
  end

  # --- valid vectors, section by section -------------------------------

  def test_valid_get_conversation_key
    VECTORS["valid"]["get_conversation_key"].each do |c|
      ck = NostrCore::Nip44.conversation_key([c["sec1"]].pack("H*"), [c["pub2"]].pack("H*"))
      assert_equal c["conversation_key"], ck.unpack1("H*")
    end
  end

  def test_valid_get_message_keys
    base = VECTORS["valid"]["get_message_keys"]
    ck = [base["conversation_key"]].pack("H*")
    base["keys"].each do |k|
      chacha_key, chacha_nonce, hmac_key = NostrCore::Nip44.message_keys(ck, [k["nonce"]].pack("H*"))
      assert_equal k["chacha_key"], chacha_key.unpack1("H*")
      assert_equal k["chacha_nonce"], chacha_nonce.unpack1("H*")
      assert_equal k["hmac_key"], hmac_key.unpack1("H*")
    end
  end

  def test_valid_calc_padded_len
    VECTORS["valid"]["calc_padded_len"].each do |(unpadded, padded)|
      assert_equal padded, NostrCore::Nip44.calc_padded_len(unpadded)
    end
  end

  def test_valid_encrypt_decrypt_exact_payloads
    VECTORS["valid"]["encrypt_decrypt"].each do |c|
      sk = [c["sec1"]].pack("H*")
      pk = pub_of(c["sec2"])
      ck = NostrCore::Nip44.conversation_key(sk, pk)
      assert_equal c["conversation_key"], ck.unpack1("H*")

      payload = NostrCore::Nip44.encrypt(sk, pk, c["plaintext"], nonce: [c["nonce"]].pack("H*"))
      assert_equal c["payload"], payload, "exact payload for #{c["plaintext"][0, 12]}"

      assert_equal c["plaintext"], NostrCore::Nip44.decrypt(sk, pk, c["payload"])
    end
  end

  def test_valid_encrypt_decrypt_long_msg
    VECTORS["valid"]["encrypt_decrypt_long_msg"].each do |c|
      plaintext = c["pattern"] * c["repeat"]
      assert_equal c["plaintext_sha256"], Digest::SHA256.hexdigest(plaintext)

      payload = NostrCore::Nip44.encrypt_raw(plaintext, [c["conversation_key"]].pack("H*"),
                                             [c["nonce"]].pack("H*"))
      assert_equal c["payload_sha256"], Digest::SHA256.hexdigest(payload)
      assert_equal plaintext, NostrCore::Nip44.decrypt_raw(payload, [c["conversation_key"]].pack("H*"))
    end
  end

  # --- invalid vectors ---------------------------------------------------

  def test_invalid_encrypt_msg_lengths_raise
    VECTORS["invalid"]["encrypt_msg_lengths"].each do |n|
      assert_raises(ArgumentError) do
        NostrCore::Nip44.encrypt_raw("x" * n, ["aa" * 16].pack("H*"), "\x00" * 32)
      end
    end
  end

  def test_invalid_get_conversation_key_raises
    VECTORS["invalid"]["get_conversation_key"].each do |c|
      assert_raises(ArgumentError) do
        NostrCore::Nip44.conversation_key([c["sec1"]].pack("H*"), [c["pub2"]].pack("H*"))
      end
    end
  end

  def test_invalid_decrypt_raises
    VECTORS["invalid"]["decrypt"].each do |c|
      assert_raises(ArgumentError) do
        NostrCore::Nip44.decrypt_raw(c["payload"], [c["conversation_key"]].pack("H*"))
      end
    end
  end

  # --- round trips with fresh keys ---------------------------------------

  def random_key
    loop do
      k = SecureRandom.bytes(32)
      i = k.unpack1("H*").to_i(16)
      return k if i.positive? && i < NostrCore::Bip340::N
    end
  end

  def test_round_trip_random_keys
    a_sk = random_key
    b_sk = random_key
    a_pk = [NostrCore::Bip340.public_key(a_sk)].pack("H*")
    b_pk = [NostrCore::Bip340.public_key(b_sk)].pack("H*")

    # conversation key is symmetric across roles
    assert_equal NostrCore::Nip44.conversation_key(a_sk, b_pk),
                 NostrCore::Nip44.conversation_key(b_sk, a_pk)

    msg = "うんち🍣 表ポあA鷗ŒéＢ逍Üß — multibyte both ways"
    payload = NostrCore::Nip44.encrypt(a_sk, b_pk, msg)
    assert_equal msg, NostrCore::Nip44.decrypt(b_sk, a_pk, payload)
    # wrong recipient keypair cannot read it
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(random_key, a_pk, payload) }
  end

  def test_round_trip_boundary_lengths_correct_recipient
    a_sk = random_key
    b_sk = random_key
    b_pk = [NostrCore::Bip340.public_key(b_sk)].pack("H*")
    [1, 32, 33, 64, 256, 4096, 65_535].each do |n|
      msg = "y" * n
      assert_equal msg, NostrCore::Nip44.decrypt(b_sk, [NostrCore::Bip340.public_key(a_sk)].pack("H*"),
                                                 NostrCore::Nip44.encrypt(a_sk, b_pk, msg))
    end
  end

  def test_encrypt_rejects_oversize_and_empty
    sk = random_key
    pk = [NostrCore::Bip340.public_key(sk)].pack("H*")
    assert_raises(ArgumentError) { NostrCore::Nip44.encrypt(sk, pk, "") }
    assert_raises(ArgumentError) { NostrCore::Nip44.encrypt(sk, pk, "x" * 65_536) }
  end

  # --- hand-mangled payloads ---------------------------------------------

  def mangled(payload, hex_index, byte)
    data = payload.unpack1("m0")
    data[hex_index] = [byte].pack("C")
    [data].pack("m0")
  end

  def test_tampered_payloads_raise
    sk = random_key
    pk = [NostrCore::Bip340.public_key(sk)].pack("H*")
    good = NostrCore::Nip44.encrypt(sk, pk, "attack at dawn")
    # MAC is the last 32 bytes of the decoded payload
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, mangled(good, -1, 0x00)) }
    # ciphertext byte flip must break the MAC, not silently decrypt
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, mangled(good, 40, 0xFF)) }
    # version byte flipped off 0x02
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, mangled(good, 0, 0x03)) }
    # future-proof '#' flag means "unknown version", not "bad base64"
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, "##{good[1..]}") }
    # too short / not base64
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, "Ag==") }
    assert_raises(ArgumentError) { NostrCore::Nip44.decrypt(sk, pk, "not base64!!") }
  end
end
