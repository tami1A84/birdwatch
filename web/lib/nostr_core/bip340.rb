# frozen_string_literal: true

require "digest"

module NostrCore
  # Pure-Ruby BIP-340 Schnorr (secp256k1 xonly). Correct but slow:
  # fine for signing; bulk verification must move to libsecp256k1 via ffi.
  module Bip340
    P = 2**256 - 2**32 - 977
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    GX = 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
    GY = 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
    G = [GX, GY]

    module_function

    def sign(msg32, seckey32, aux32)
      d0 = to_int(seckey32)
      return nil unless d0.positive? && d0 < N

      pub = point_mul(G, d0)
      d = pub[1].odd? ? N - d0 : d0
      t = xor_bytes(to_bytes(d, 32), tagged_hash("BIP0340/aux", aux32))
      k0 = to_int(tagged_hash("BIP0340/nonce", t + to_bytes(pub[0], 32) + msg32)) % N
      return nil if k0.zero?

      r_point = point_mul(G, k0)
      k = r_point[1].odd? ? N - k0 : k0
      e = to_int(tagged_hash("BIP0340/challenge",
                             to_bytes(r_point[0], 32) + to_bytes(pub[0], 32) + msg32)) % N
      to_bytes(r_point[0], 32) + to_bytes((k + e * d) % N, 32)
    end

    def verify(pubkey32, msg32, sig64)
      pub = lift_x(to_int(pubkey32))
      return false unless pub

      r = to_int(sig64[0, 32])
      s = to_int(sig64[32, 32])
      return false if r >= P || s >= N

      e = to_int(tagged_hash("BIP0340/challenge",
                             sig64[0, 32] + pubkey32 + msg32)) % N
      r_point = point_add(point_mul(G, s), point_mul(pub, N - e))
      return false unless r_point && r_point[1].even? && r_point[0] == r

      true
    end

    def public_key(seckey32)
      to_bytes(point_mul(G, to_int(seckey32))[0], 32).unpack1("H*")
    end

    # 33-byte compressed point (02/03 + x). The nonce and challenge hashes
    # use this form, matching the BIP-340 reference implementation.
    def compressed(point)
      [(point[1].even? ? 2 : 3)].pack("C") + to_bytes(point[0], 32)
    end

    def tagged_hash(tag, msg)
      t = Digest::SHA256.digest(tag)
      Digest::SHA256.digest(t + t + msg)
    end

    def lift_x(x)
      return nil unless x < P

      y_sq = (x**3 + 7) % P
      y = pow_mod(y_sq, (P + 1) / 4, P)
      return nil unless (y * y) % P == y_sq

      y.even? ? [x, y] : [x, P - y]
    end

    def point_mul(point, scalar)
      result = nil
      point = [point[0] % P, point[1] % P]
      while scalar.positive?
        result = point_add(result, point) if scalar.odd?
        point = point_add(point, point)
        scalar >>= 1
      end
      result
    end

    def point_add(p1, p2)
      return p2 if p1.nil?
      return p1 if p2.nil?

      x1, y1 = p1
      x2, y2 = p2
      return nil if x1 == x2 && (y1 + y2) % P == 0

      lam = if p1 == p2
              3 * x1 * x1 % P * pow_mod(2 * y1, P - 2, P) % P
            else
              (y2 - y1) % P * pow_mod((x2 - x1) % P, P - 2, P) % P
            end
      x3 = (lam * lam - x1 - x2) % P
      [(x3), (lam * (x1 - x3) - y1) % P]
    end

    def pow_mod(base, exp, mod)
      result = 1
      base %= mod
      while exp.positive?
        result = result * base % mod if exp.odd?
        base = base * base % mod
        exp >>= 1
      end
      result
    end

    def to_int(bytes) = bytes.unpack1("H*").to_i(16)
    def to_bytes(int, len) = [int.to_s(16).rjust(len * 2, "0")].pack("H*")
    def xor_bytes(a, b) = a.bytes.zip(b.bytes).map { |x, y| x ^ y }.pack("C*")
  end
end
