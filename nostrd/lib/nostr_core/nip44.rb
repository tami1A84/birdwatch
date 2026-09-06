# frozen_string_literal: true

require "digest"
require "openssl"
require "base64"
require "securerandom"
require_relative "bip340"

module NostrCore
  # NIP-44 v2 encrypted payloads (secp256k1 ECDH, HKDF, padding, ChaCha20,
  # HMAC-SHA256, base64) — pure Ruby per .scratch/specs/nip44.md. Slow but
  # correct; the daemon only uses it for kind-24133 bunker traffic, so
  # throughput does not matter.
  module Nip44
    VERSION = 0x02
    MIN_PLAINTEXT = 1
    # The NIP text mentions a 2^32-1 theoretical maximum, but the vectors
    # (.scratch/specs/nip44-v2.json invalid.encrypt_msg_lengths) reject
    # 65536 — so encrypt accepts 1..65535, matching common implementations.
    MAX_PLAINTEXT = 65_535
    EXTENDED_PREFIX_THRESHOLD = 65_536
    # DoS guard: a valid max-size payload decodes to ~65.6 KiB; anything
    # beyond 1 MiB decoded is refused before base64/ChaCha work is done.
    MAX_PAYLOAD_BYTES = 1024 * 1024
    SALT = "nip44-v2"

    module_function

    # --- public convenience API (daemon use) -----------------------------

    # ECDH + HKDF conversation key between our seckey and their x-only
    # pubkey (32-byte binaries). Symmetric: conv(a, B) == conv(b, A).
    def conversation_key(sk32, pk32)
      shared_x = ecdh_x(sk32, pk32)
      # HKDF-extract(ikm=shared_x, salt=utf8("nip44-v2")) — one HMAC round,
      # output length == hash length so no expand step is needed.
      hmac(SALT, shared_x)
    end

    # HKDF-expand(prk=conversation_key, info=nonce, L=76) sliced into
    # [chacha_key 32][chacha_nonce 12][hmac_key 32].
    def message_keys(conversation_key, nonce)
      raise ArgumentError, "invalid conversation_key length" if conversation_key.bytesize != 32
      raise ArgumentError, "invalid nonce length" if nonce.bytesize != 32

      okm = hkdf_expand(conversation_key, nonce, 76)
      [okm[0, 32], okm[32, 12], okm[44, 32]]
    end

    # Encrypt plaintext to pk32 using our sk32. Pass nonce: only in tests —
    # production always draws 32 fresh CSPRNG bytes.
    def encrypt(sk32, pk32, plaintext, nonce: nil)
      encrypt_raw(plaintext, conversation_key(sk32, pk32),
                  nonce || SecureRandom.bytes(32))
    end

    # Decrypt a payload sent to us (sk32) by the holder of pk32.
    def decrypt(sk32, pk32, payload_b64)
      decrypt_raw(payload_b64, conversation_key(sk32, pk32))
    end

    # --- spec-level API (test vectors operate on raw keys) ---------------

    def encrypt_raw(plaintext, conversation_key, nonce)
      raise ArgumentError, "invalid conversation_key length" if conversation_key.bytesize != 32
      raise ArgumentError, "invalid nonce length" if nonce.bytesize != 32

      keys = message_keys(conversation_key, nonce)
      chacha_key, chacha_nonce, hmac_key = keys
      padded = pad(plaintext)
      ciphertext = chacha20(chacha_key, chacha_nonce, padded)
      mac = hmac_aad(hmac_key, ciphertext, nonce)
      base64_strict_encode(([VERSION].pack("C") + nonce + ciphertext + mac))
    end

    def decrypt_raw(payload_b64, conversation_key)
      nonce, ciphertext, mac = decode_payload(payload_b64)
      chacha_key, chacha_nonce, hmac_key = message_keys(conversation_key, nonce)
      calculated = hmac_aad(hmac_key, ciphertext, nonce)
      raise ArgumentError, "invalid MAC" unless constant_time_eq(calculated, mac)

      unpad(chacha20(chacha_key, chacha_nonce, ciphertext))
    end

    # Powers-of-two padding with a 32-byte floor; see spec pseudocode.
    def calc_padded_len(unpadded_len)
      raise ArgumentError, "invalid plaintext length" if
        unpadded_len < MIN_PLAINTEXT || unpadded_len > 0xFFFFFFFF

      return 32 if unpadded_len <= 32

      # floor(log2(len-1)) == (len-1).bit_length - 1 for integers >= 1.
      next_power = 1 << (unpadded_len - 1).bit_length
      chunk = next_power <= 256 ? 32 : next_power / 8
      chunk * ((unpadded_len - 1) / chunk + 1)
    end

    # --- internals --------------------------------------------------------

    # Unhashed ECDH: x-coordinate of (sk * lift_x(pk)). Both sides validated
    # per BIP-340 (scalar in [1, n-1]; pubkey a real curve point — this is
    # what rejects the twist/zero-point vectors).
    def ecdh_x(sk32, pk32)
      raise ArgumentError, "invalid secret key length" unless sk32.is_a?(String) && sk32.bytesize == 32
      raise ArgumentError, "invalid pubkey length" unless pk32.is_a?(String) && pk32.bytesize == 32

      d = Bip340.to_int(sk32)
      raise ArgumentError, "invalid secret key" unless d.positive? && d < Bip340::N

      point = Bip340.lift_x(Bip340.to_int(pk32))
      raise ArgumentError, "invalid pubkey" unless point

      Bip340.to_bytes(Bip340.point_mul(point, d)[0], 32)
    end

    def hkdf_expand(prk, info, length)
      okm = +"".b
      t = +"".b
      counter = 1
      while okm.bytesize < length
        t = hmac(prk, t + info + [counter].pack("C"))
        okm << t
        counter += 1
      end
      okm[0, length]
    end

    def hmac(key, data)
      OpenSSL::HMAC.digest("SHA256", key, data)
    end

    # AAD construction from the spec: MAC covers nonce (32 bytes) || ciphertext.
    def hmac_aad(key, message, aad)
      raise ArgumentError, "AAD associated data must be 32 bytes" if aad.bytesize != 32

      hmac(key, aad + message)
    end

    def pad(plaintext)
      raise ArgumentError, "plaintext must be a string" unless plaintext.is_a?(String)

      unpadded = plaintext.b
      unpadded_len = unpadded.bytesize
      raise ArgumentError, "invalid plaintext length" if
        unpadded_len < MIN_PLAINTEXT || unpadded_len > MAX_PLAINTEXT

      prefix = if unpadded_len >= EXTENDED_PREFIX_THRESHOLD
                 # A zero u16 marks the extended 6-byte prefix form.
                 "\x00\x00".b + [unpadded_len].pack("N")
               else
                 [unpadded_len].pack("n")
               end
      prefix + unpadded + ("\x00".b * (calc_padded_len(unpadded_len) - unpadded_len))
    end

    def unpad(padded)
      first_two = padded[0, 2].unpack1("n")
      if first_two.zero?
        unpadded_len = padded[2, 4].unpack1("N")
        raise ArgumentError, "invalid padding" if unpadded_len < EXTENDED_PREFIX_THRESHOLD

        prefix_len = 6
      else
        unpadded_len = first_two
        prefix_len = 2
      end
      unpadded = padded[prefix_len, unpadded_len]
      raise ArgumentError, "invalid padding" if
        unpadded_len.zero? || unpadded.nil? || unpadded.bytesize != unpadded_len ||
        padded.bytesize != prefix_len + calc_padded_len(unpadded_len)

      unpadded.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "invalid plaintext encoding" unless unpadded.valid_encoding?

      unpadded
    end

    def decode_payload(payload)
      raise ArgumentError, "unknown version" if payload.to_s.empty? || payload.start_with?("#")
      raise ArgumentError, "invalid payload size" if payload.bytesize < 132
      raise ArgumentError, "invalid payload size" if payload.bytesize > MAX_PAYLOAD_BYTES * 4 / 3 + 4
      raise ArgumentError, "invalid base64" unless
        payload.match?(/\A[A-Za-z0-9+\/]+={0,2}\z/) && (payload.bytesize % 4).zero?

      data = Base64.decode64(payload)
      dlen = data.bytesize
      raise ArgumentError, "invalid data size" if dlen < 99 || dlen > MAX_PAYLOAD_BYTES

      version = data.getbyte(0)
      raise ArgumentError, "unknown version #{version}" unless version == VERSION

      [data[1, 32], data[33, dlen - 65], data[dlen - 32, 32]]
    end

    # ChaCha20 (RFC 8439): 12-byte nonce, 32-bit block counter starting at 0.
    def chacha20(key, nonce, data)
      raise ArgumentError, "invalid chacha key length" if key.bytesize != 32
      raise ArgumentError, "invalid chacha nonce length" if nonce.bytesize != 12

      state = initial_state(key, nonce)
      out = +"".b
      counter = 0
      bytes = data.bytes
      i = 0
      while i < bytes.size
        out << keystream_block(state, counter, i, bytes)
        counter += 1
        i += 64
      end
      out
    end

    def keystream_block(state, counter, offset, bytes)
      block = chacha_block(state, counter)
      len = [64, bytes.size - offset].min
      (0...len).map { |j| bytes[offset + j] ^ block[j] }.pack("C*")
    end

    def initial_state(key, nonce)
      # RFC 8439 layout: 4 constants, 8 key words, counter (set per block), 3 nonce words.
      [0x61707865, 0x3320646E, 0x79622D32, 0x6B206574] +
        key.unpack("V8") + [0] + nonce.unpack("V3")
    end

    def chacha_block(state, counter)
      # The counter lives in state word 12 for BOTH the rounds and the final
      # addition — leaving it out of the add made every block n-th word off
      # by exactly `counter` (block 0 passed, block 1 diverged).
      base = state[0, 12] + [counter & 0xFFFFFFFF] + state[13, 3]
      x = base.dup
      10.times do
        quarter_round(x, 0, 4, 8, 12)
        quarter_round(x, 1, 5, 9, 13)
        quarter_round(x, 2, 6, 10, 14)
        quarter_round(x, 3, 7, 11, 15)
        quarter_round(x, 0, 5, 10, 15)
        quarter_round(x, 1, 6, 11, 12)
        quarter_round(x, 2, 7, 8, 13)
        quarter_round(x, 3, 4, 9, 14)
      end
      (0...16).map { |i| (x[i] + base[i]) & 0xFFFFFFFF }.pack("V16").bytes
    end

    def quarter_round(s, a, b, c, d)
      s[a] = s[a] + s[b] & 0xFFFFFFFF
      s[d] = rotl32(s[d] ^ s[a], 16)
      s[c] = s[c] + s[d] & 0xFFFFFFFF
      s[b] = rotl32(s[b] ^ s[c], 12)
      s[a] = s[a] + s[b] & 0xFFFFFFFF
      s[d] = rotl32(s[d] ^ s[a], 8)
      s[c] = s[c] + s[d] & 0xFFFFFFFF
      s[b] = rotl32(s[b] ^ s[c], 7)
    end

    def rotl32(v, n)
      ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF
    end

    def base64_strict_encode(data)
      [data].pack("m0") # RFC 4648 with padding, no newlines
    end

    def constant_time_eq(a, b)
      return false unless a.bytesize == b.bytesize

      diff = 0
      a.bytes.zip(b.bytes) { |x, y| diff |= x ^ y }
      diff.zero?
    end
  end
end
