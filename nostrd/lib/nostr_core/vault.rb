# frozen_string_literal: true

require "openssl"
require "securerandom"
require "base64"
require_relative "bech32"
require_relative "bip340"

module NostrCore
  # Encrypted key vault at rest. Two formats:
  #
  # - NIP-49 "ncryptsec1…" (official): XChaCha20-Poly1305 over the raw
  #   seckey, scrypt-derived key, bech32 HRP "ncryptsec". 91 bytes before
  #   bech32: version | logn | salt(16) | nonce(24) | ksb(1) | ct(48 = 32 + 16 tag).
  # - Legacy NVAULT1: base64(MAGIC, logn, salt16, iv16, AES-256-CBC ct).
  #   Unlock-only: kept so pre-NIP-49 vault files keep opening.
  #
  # The official NIP-49 test vector in test/vault_test.rb is the correctness
  # oracle for the layout and the pure-Ruby HChaCha20 below (Ruby/OpenSSL
  # ships ChaCha20-Poly1305 but no XChaCha20).
  module Vault
    # Legacy NVAULT1 marker byte (layout: MAGIC, logn, salt, iv, ciphertext).
    MAGIC = "\x00"

    VERSION = 0x02 # NIP-49 version number
    KSB = 0x02 # key-security byte: "client does not track key handling"

    module_function

    # NIP-49 only: "ncryptsec1…" -> 64-hex seckey. Wrong passphrase, bad
    # checksum, or any tampering -> ArgumentError.
    def decrypt(pass, ncryptsec_str)
      hrp, words = Bech32.decode(ncryptsec_str.to_s)
      raise ArgumentError, "expected ncryptsec, got #{hrp}" unless hrp == "ncryptsec"

      blob = Bech32.convert_bits(words, from: 5, to: 8).pack("C*")
      raise ArgumentError, "ncryptsec blob must be 91 bytes, got #{blob.bytesize}" unless
        blob.bytesize == 91
      raise ArgumentError, "unsupported version #{blob.getbyte(0)}" unless blob.getbyte(0) == VERSION

      logn = blob.getbyte(1)
      raise ArgumentError, "logn out of range" unless logn.between?(1, 22)

      salt = blob.byteslice(2, 16)
      nonce = blob.byteslice(18, 24)
      ksb = blob.byteslice(42, 1)
      ct = blob.byteslice(43, 48)
      key = scrypt_key(pass, salt, logn)
      subkey = hchacha20(key, nonce.byteslice(0, 16))
      # AEAD_XCHACHA20_POLY1305: OpenSSL's 12-byte-nonce ChaCha20-Poly1305
      # with 0x00000000 || nonce[16..23], AAD = the ksb byte itself.
      nonce12 = ("\x00\x00\x00\x00".b + nonce.byteslice(16, 8))
      begin
        cipher = OpenSSL::Cipher.new("chacha20-poly1305")
        cipher.decrypt
        cipher.key = subkey
        cipher.iv = nonce12
        cipher.auth_data = ksb
        cipher.auth_tag = ct.byteslice(32, 16) # tag mismatch -> CipherError
        (cipher.update(ct.byteslice(0, 32)) + cipher.final).unpack1("H*")
      rescue OpenSSL::Cipher::CipherError
        raise ArgumentError, "decryption failed (wrong passphrase or corrupt blob)"
      end
    end

    # NIP-49 encrypt: -> "ncryptsec1…". Non-deterministic (random salt+nonce).
    def encrypt(pass, seckey_hex, logn: 16)
      sk = seckey_hex.to_s
      raise ArgumentError, "seckey must be 64 hex chars" unless sk.match?(/\A[0-9a-fA-F]{64}\z/)
      raise ArgumentError, "logn must be 1..22" unless logn.to_i.between?(1, 22)

      salt = SecureRandom.random_bytes(16)
      nonce = SecureRandom.random_bytes(24)
      ksb = [KSB].pack("C") # AAD = the single key-security byte
      key = scrypt_key(pass, salt, logn.to_i)
      subkey = hchacha20(key, nonce.byteslice(0, 16))
      nonce12 = ("\x00\x00\x00\x00".b + nonce.byteslice(16, 8))
      cipher = OpenSSL::Cipher.new("chacha20-poly1305")
      cipher.encrypt
      cipher.key = subkey
      cipher.iv = nonce12
      cipher.auth_data = ksb
      ct = cipher.update([sk].pack("H*")) + cipher.final
      blob = [VERSION, logn.to_i].pack("C*") + salt + nonce + ksb + ct + cipher.auth_tag
      Bech32.encode("ncryptsec", blob)
    end

    # Dispatch: NIP-49 for "ncryptsec1…", legacy NVAULT1 base64 otherwise.
    def unlock(pass, blob)
      s = blob.to_s.strip
      return decrypt(pass, s) if s.start_with?("ncryptsec")

      legacy_unlock(pass, s)
    end

    # Create a NIP-49 vault blob from scratch (fresh key or imported nsec).
    def create(passphrase:, seckey_hex:)
      sk = seckey_hex.to_s
      raise ArgumentError, "seckey must be 64 hex chars" unless sk.match?(/\A[0-9a-fA-F]{64}\z/)

      { blob: encrypt(passphrase, sk), pubkey_hex: Bip340.public_key([sk].pack("H*")) }
    end

    # --- internals ---

    def legacy_unlock(pass, b64)
      raw = Base64.decode64(b64)
      raise ArgumentError, "not a vault blob" unless raw.byteslice(0, 1) == MAGIC

      logn = raw.getbyte(1)
      salt = raw.byteslice(2, 16)
      iv = raw.byteslice(18, 16)
      ct = raw.byteslice(34..)
      raise ArgumentError, "truncated vault blob" unless
        salt && iv && ct && !ct.empty? && (ct.bytesize % 16).zero?

      key = OpenSSL::KDF.scrypt(normalize(pass), salt: salt, N: 2**logn, r: 8, p: 1, length: 32)
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      pt = cipher.update(ct) + cipher.final
      raise ArgumentError, "vault plaintext must be 32 bytes" unless pt.bytesize == 32

      pt.unpack1("H*")
    rescue OpenSSL::Cipher::CipherError
      raise ArgumentError, "decryption failed (wrong passphrase or corrupt blob)"
    end

    # NIP-49: password is NFKC-normalized before scrypt so equivalent
    # unicode forms unlock identically on every client.
    def scrypt_key(pass, salt, logn)
      OpenSSL::KDF.scrypt(normalize(pass), salt: salt, N: 2**logn, r: 8, p: 1, length: 32)
    end

    def normalize(pass)
      pass.to_s.unicode_normalize(:nfkc)
    end

    # HChaCha20 (draft-irtf-cfrg-xchacha §2.2): 32-byte subkey from the key
    # and the FIRST 16 nonce bytes. 20 ChaCha rounds, then the words 0-3 and
    # 12-15 of the final state WITHOUT feed-forward addition of the input.
    def hchacha20(key, nonce16)
      st = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            *key.unpack("V8"), *nonce16.unpack("V4")]
      10.times do
        qr(st, 0, 4, 8, 12); qr(st, 1, 5, 9, 13); qr(st, 2, 6, 10, 14); qr(st, 3, 7, 11, 15)
        qr(st, 0, 5, 10, 15); qr(st, 1, 6, 11, 12); qr(st, 2, 7, 8, 13); qr(st, 3, 4, 9, 14)
      end
      (st[0, 4] + st[12, 4]).pack("V*")
    end

    # ChaCha20 quarter round over state indices a,b,c,d (in place).
    def qr(st, a, b, c, d)
      st[a] = (st[a] + st[b]) & 0xffffffff; st[d] = rotl(st[d] ^ st[a], 16)
      st[c] = (st[c] + st[d]) & 0xffffffff; st[b] = rotl(st[b] ^ st[c], 12)
      st[a] = (st[a] + st[b]) & 0xffffffff; st[d] = rotl(st[d] ^ st[a], 8)
      st[c] = (st[c] + st[d]) & 0xffffffff; st[b] = rotl(st[b] ^ st[c], 7)
    end

    def rotl(x, n) = ((x << n) | (x >> (32 - n))) & 0xffffffff
  end
end
