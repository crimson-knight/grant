require "random/secure"
require "../vendor/beryl/crypto"

module Grant::Encryption
  # Encrypts and decrypts the value of one encrypted attribute.
  #
  # ## Format version 2 (written by `encrypt`)
  #
  #     header (1 byte) | nonce (24 bytes) | ciphertext | tag (16 bytes)
  #
  # XChaCha20-Poly1305. The header byte holds the version in its low seven
  # bits and the deterministic flag in bit 7, and is authenticated with the
  # value. The cipher key is derived from the attribute key with HKDF-SHA256.
  # A deterministic value takes its nonce from HMAC-SHA256 of the plaintext
  # under a second derived key, so equal plaintext gives equal ciphertext and
  # the column can be queried; any other value takes a random nonce.
  #
  # ## Format version 1 (still read)
  #
  #     header (1 byte) | initialization vector (16 bytes) | ciphertext | HMAC tag (32 bytes)
  #
  # AES-256-CBC with HMAC-SHA256, the format of Grant up to 0.24.0. `decrypt`
  # reads it for as long as such values exist, and `encrypt_in_version_1`
  # reproduces the deterministic form so a lookup still finds rows written
  # before the upgrade.
  #
  # The primitives are Beryl's, in Crystal; nothing here calls OpenSSL.
  class Cipher
    # The version `encrypt` writes.
    VERSION = 2_u8

    # The earlier version, which `decrypt` still reads.
    VERSION_1 = 1_u8

    # Nonce size of version 2 (XChaCha20-Poly1305).
    NONCE_SIZE = 24

    # Tag size of version 2 (Poly1305).
    TAG_SIZE = 16

    # Initialization vector size of version 1 (AES-CBC).
    IV_SIZE = 16

    # HMAC size of version 1 (HMAC-SHA256).
    HMAC_SIZE = 32

    # Header flags. NOTE: the header byte is `version (low 7 bits) + flags (high bit)`,
    # and decrypt reads the version as `header & 0x7F`. The flag therefore MUST live in
    # bit 7 (0x80).
    module Flags
      DETERMINISTIC = 0x80_u8
    end

    # Smallest version 2 payload: header byte, nonce, one byte of ciphertext
    # and the tag. (An empty value is stored as empty bytes, never encrypted.)
    MIN_PAYLOAD_SIZE = 1 + NONCE_SIZE + 1 + TAG_SIZE

    # Smallest version 1 payload: header byte, IV, one cipher block and the HMAC.
    MIN_VERSION_1_PAYLOAD_SIZE = 1 + IV_SIZE + 16 + HMAC_SIZE

    private ENCRYPTION_KEY_PURPOSE          = "grant cipher v2 encryption"
    private DETERMINISTIC_NONCE_KEY_PURPOSE = "grant cipher v2 deterministic nonce"

    class EncryptionError < Grant::ErrorBase
    end

    class DecryptionError < Grant::ErrorBase
    end

    # Returns *plaintext* encrypted under *key* in format version 2. With
    # *deterministic*, equal plaintext gives equal bytes. An empty
    # *plaintext* is returned as empty bytes.
    def self.encrypt(plaintext : String, key : Bytes, deterministic : Bool = false) : Bytes
      return Bytes.empty if plaintext.empty?

      plaintext_bytes = plaintext.to_slice
      header = deterministic ? VERSION | Flags::DETERMINISTIC : VERSION
      payload = Bytes.new(1 + NONCE_SIZE + plaintext_bytes.size + TAG_SIZE)
      payload[0] = header
      nonce = payload[1, NONCE_SIZE]
      if deterministic
        nonce_key = derive_version_2_key(key, DETERMINISTIC_NONCE_KEY_PURPOSE)
        hmac_sha256(nonce_key, plaintext_bytes)[0, NONCE_SIZE].copy_to(nonce)
      else
        Random::Secure.random_bytes(nonce)
      end

      version_2_cipher(key).encrypt(
        plaintext_bytes,
        into: payload[1 + NONCE_SIZE, plaintext_bytes.size + TAG_SIZE],
        nonce: nonce,
        associated_data: payload[0, 1],
      )
      payload
    rescue ex : Grant::Beryl::Error
      raise EncryptionError.new("Encryption failed: #{ex.message}")
    end

    # Returns *plaintext* encrypted under *key* in format version 1
    # (AES-256-CBC with HMAC-SHA256). Grant writes version 2; this exists so
    # that a query on a deterministic attribute can also match the rows an
    # earlier Grant wrote, whose bytes it reproduces exactly.
    def self.encrypt_in_version_1(plaintext : String, key : Bytes, deterministic : Bool = false) : Bytes
      return Bytes.empty if plaintext.empty?

      enc_key, mac_key = derive_version_1_keys(key)
      plaintext_bytes = plaintext.to_slice
      iv = deterministic ? hmac_sha256(enc_key, plaintext_bytes)[0, IV_SIZE] : Random::Secure.random_bytes(IV_SIZE)
      ciphertext = Grant::Beryl::Crypto::Compatibility::AESCBC.new(enc_key).encrypt(plaintext_bytes, initialization_vector: iv)

      payload = Bytes.new(1 + IV_SIZE + ciphertext.size + HMAC_SIZE)
      payload[0] = deterministic ? VERSION_1 | Flags::DETERMINISTIC : VERSION_1
      iv.copy_to(payload + 1)
      ciphertext.copy_to(payload + 1 + IV_SIZE)
      hmac_sha256(mac_key, payload[0, payload.size - HMAC_SIZE]).copy_to(payload + (payload.size - HMAC_SIZE))
      payload
    rescue ex : Grant::Beryl::Error
      raise EncryptionError.new("Encryption failed: #{ex.message}")
    end

    # Whether *bytes* has the shape of a payload this cipher wrote, in either
    # version: long enough and carrying a known version in the header byte.
    # It does not verify the tag, so it is the cheap check that tells
    # ciphertext from plaintext without raising.
    def self.encrypted_payload?(bytes : Bytes) : Bool
      return false if bytes.empty?

      version = bytes[0] & 0x7F_u8
      if version == VERSION
        bytes.size >= MIN_PAYLOAD_SIZE
      elsif version == VERSION_1
        bytes.size >= MIN_VERSION_1_PAYLOAD_SIZE
      else
        false
      end
    end

    # Whether the header byte marks a deterministic payload (which key wrote it).
    def self.deterministic_payload?(bytes : Bytes) : Bool
      !bytes.empty? && (bytes[0] & Flags::DETERMINISTIC) != 0
    end

    # Returns the format version the header byte of *bytes* names, or nil for
    # empty bytes.
    def self.payload_version(bytes : Bytes) : UInt8?
      bytes.empty? ? nil : bytes[0] & 0x7F_u8
    end

    # Decrypt data with the given key
    def self.decrypt(encrypted : Bytes, key : Bytes) : String
      decrypt?(encrypted, key) || raise DecryptionError.new("HMAC verification failed - data may have been tampered with")
    end

    # Like `decrypt`, but returns `nil` instead of raising when the tag does
    # not match *key*. A wrong key is the normal outcome while trying the
    # current key and then the previous ones, so it must not cost an exception.
    # Malformed payloads still raise `DecryptionError`.
    def self.decrypt?(encrypted : Bytes, key : Bytes) : String?
      return "" if encrypted.empty?

      version = encrypted[0] & 0x7F_u8
      if version == VERSION
        decrypt_version_2(encrypted, key)
      else
        decrypt_version_1(encrypted, key)
      end
    end

    private def self.decrypt_version_2(encrypted : Bytes, key : Bytes) : String?
      raise DecryptionError.new("Encrypted data too short") if encrypted.size < 1 + NONCE_SIZE + TAG_SIZE

      opened = version_2_cipher(key).decrypt(
        encrypted[1 + NONCE_SIZE, encrypted.size - 1 - NONCE_SIZE],
        nonce: encrypted[1, NONCE_SIZE],
        associated_data: encrypted[0, 1],
      )
      opened ? String.new(opened) : nil
    rescue ex : Grant::Beryl::Error
      raise DecryptionError.new("Decryption failed: #{ex.message}")
    end

    private def self.decrypt_version_1(encrypted : Bytes, key : Bytes) : String?
      raise DecryptionError.new("Encrypted data too short") if encrypted.size < 1 + HMAC_SIZE

      enc_key, mac_key = derive_version_1_keys(key)
      payload = encrypted[0, encrypted.size - HMAC_SIZE]
      provided_hmac = encrypted[encrypted.size - HMAC_SIZE, HMAC_SIZE]
      return unless Grant::Beryl::Crypto::V1::HMAC(Grant::Beryl::Crypto::V1::SHA256).verify(payload, provided_hmac, key: mac_key)

      version = payload[0] & 0x7F_u8
      raise DecryptionError.new("Unsupported encryption version: #{version}") unless version == VERSION_1
      raise DecryptionError.new("Encrypted data too short for IV") if payload.size < 1 + IV_SIZE

      # The stored IV is the exact IV used to encrypt (deterministic or random).
      opened = Grant::Beryl::Crypto::Compatibility::AESCBC.new(enc_key).decrypt(
        payload[1 + IV_SIZE, payload.size - 1 - IV_SIZE],
        initialization_vector: payload[1, IV_SIZE],
      )
      raise DecryptionError.new("Decryption failed: the padding of the value is invalid") unless opened
      String.new(opened)
    rescue ex : Grant::Beryl::Error
      raise DecryptionError.new("Decryption failed: #{ex.message}")
    end

    private def self.version_2_cipher(key : Bytes) : Grant::Beryl::Crypto::V1::XChaCha20Poly1305
      Grant::Beryl::Crypto::V1::XChaCha20Poly1305.new(derive_version_2_key(key, ENCRYPTION_KEY_PURPOSE))
    end

    private def self.derive_version_2_key(key : Bytes, purpose : String) : Bytes
      Grant::Beryl::Crypto::V1::HKDF(Grant::Beryl::Crypto::V1::SHA256).derive_key(key, info: purpose, bytesize: 32)
    end

    # The two keys of version 1: one HMAC-SHA256 of a fixed label each,
    # under the attribute key.
    private def self.derive_version_1_keys(master_key : Bytes) : Tuple(Bytes, Bytes)
      {hmac_sha256(master_key, "encryption".to_slice), hmac_sha256(master_key, "authentication".to_slice)}
    end

    private def self.hmac_sha256(key : Bytes, message : Bytes) : Bytes
      Grant::Beryl::Crypto::V1::HMAC(Grant::Beryl::Crypto::V1::SHA256).authenticate(message, key: key)
    end
  end
end
