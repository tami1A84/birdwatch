# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/nostr_core/bech32"

# Roundtrip against a known NIP-19 vector: nsec of all-zero key.
class Bech32Test < Minitest::Test
  def test_nsec_to_hex_accepts_hex_and_bech32
    hex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    assert_equal hex, NostrCore::Bech32.nsec_to_hex(hex)
    assert_equal hex, NostrCore::Bech32.nsec_to_hex("nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5")
  end

  def test_nsec_to_hex_rejects_garbage
    assert_raises(ArgumentError) { NostrCore::Bech32.nsec_to_hex("nsec1bad") }
    assert_raises(ArgumentError) { NostrCore::Bech32.nsec_to_hex("") }
  end

  def test_npub_roundtrip
    hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    npub = NostrCore::Bech32.hex_to_npub(hex)
    assert_equal "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6", npub
    hrp, words = NostrCore::Bech32.decode(npub)
    assert_equal "npub", hrp
    assert_equal hex, NostrCore::Bech32.convert_bits(words, from: 5, to: 8).pack("C*").unpack1("H*")
  end
end
