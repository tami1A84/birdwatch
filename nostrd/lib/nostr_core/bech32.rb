# frozen_string_literal: true

module NostrCore
  # Minimal bech32 for NIP-19 entities we actually touch: nsec (secret key in)
  # and npub (display out) — plus generic encode for NIP-49 ncryptsec.
  # Decode only what we can validate; hex stays the internal representation.
  module Bech32
    CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3].freeze

    module_function

    def polymod(values)
      chk = 1
      values.each do |v|
        top = chk >> 25
        chk = ((chk & 0x1ffffff) << 5) ^ v
        5.times { |i| chk ^= GEN[i] if ((top >> i) & 1) == 1 }
      end
      chk
    end

    def hrp_expand(hrp)
      b = hrp.downcase.bytes
      b.map { |c| c >> 5 } + [0] + b.map { |c| c & 31 }
    end

    # Generic bech32 encode (legacy checksum, per NIP-49): bytes -> "hrp1…"
    def encode(hrp, bytes)
      words = convert_bits(bytes.bytes, from: 8, to: 5, pad: true)
      checksum = polymod(hrp_expand(hrp) + words + [0, 0, 0, 0, 0, 0]) ^ 1
      chk_words = 6.times.map { |i| (checksum >> 5 * (5 - i)) & 31 }
      "#{hrp}1" + (words + chk_words).map { |w| CHARSET[w] }.join
    end

    # bech32 decode of a NIP-19 entity -> [hrp, data_words]
    def decode(str)
      s = str.strip.downcase
      pos = s.rindex("1") or raise ArgumentError, "not bech32"
      hrp = s[0...pos]
      raise ArgumentError, "bad hrp" if hrp.empty? || hrp.length < 1

      data = s[(pos + 1)..].chars.map { |c| CHARSET.index(c) or raise ArgumentError, "bad char" }
      raise ArgumentError, "bad checksum" if polymod(hrp_expand(hrp) + data) != 1

      [hrp, data[0...-6]] # strip 6 checksum words
    end

    def convert_bits(words, from: 5, to: 8, pad: false)
      acc = 0
      bits = 0
      out = []
      maxv = (1 << to) - 1
      words.each do |w|
        raise ArgumentError, "bad word" if w.negative? || w >= (1 << from)

        acc = (acc << from) | w
        bits += from
        while bits >= to
          bits -= to
          out << ((acc >> bits) & maxv)
        end
      end
      if pad
        out << ((acc << (to - bits)) & maxv) if bits.positive?
      elsif bits >= from || ((acc << (to - bits)) & maxv).positive?
        raise ArgumentError, "non-zero padding"
      end
      out
    end

    # "nsec1..." or 64-hex -> hex seckey (validation happens in Bip340/caller)
    def nsec_to_hex(str)
      s = str.strip
      return s if s.match?(/\A[0-9a-fA-F]{64}\z/)

      hrp, words = decode(s)
      raise ArgumentError, "expected nsec, got #{hrp}" unless hrp == "nsec"

      convert_bits(words, from: 5, to: 8).pack("C*").unpack1("H*")
    end

    def hex_to_npub(hex)
      words = convert_bits([hex].pack("H*").bytes, from: 8, to: 5, pad: true)
      checksum = polymod(hrp_expand("npub") + words + [0, 0, 0, 0, 0, 0]) ^ 1
      chk_words = 6.times.map { |i| (checksum >> 5 * (5 - i)) & 31 }
      "npub1" + (words + chk_words).map { |w| CHARSET[w] }.join
    end
  end
end
