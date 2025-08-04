require "openssl"
require "random/secure"

module Granite::Encryption
  # Handles encryption and decryption using AES-256-CBC with HMAC-SHA256
  # This uses Encrypt-then-MAC construction for authenticated encryption
  class Cipher
    # Cipher algorithm - using CBC since GCM tag operations aren't available in Crystal
    ALGORITHM = "aes-256-cbc"
    
    # IV size for CBC mode (128 bits / 16 bytes)
    IV_SIZE = 16
    
    # HMAC size (256 bits / 32 bytes for SHA256)
    HMAC_SIZE = 32
    
    # Header format version
    VERSION = 1_u8
    
    # Header flags
    module Flags
      DETERMINISTIC = 0x01_u8
    end
    
    class EncryptionError < Exception
    end
    
    class DecryptionError < Exception
    end
    
    # Encrypt data with the given key using AES-256-CBC and HMAC-SHA256
    def self.encrypt(plaintext : String, key : Bytes, deterministic : Bool = false) : Bytes
      return Bytes.empty if plaintext.empty?
      
      # Derive separate keys for encryption and HMAC
      enc_key, mac_key = derive_keys(key)
      
      plaintext_bytes = plaintext.to_slice
      
      # Initialize cipher
      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.encrypt
      cipher.key = enc_key
      
      # Generate or derive IV
      iv = if deterministic
        # For deterministic encryption, derive IV from content
        derive_deterministic_iv(plaintext_bytes, enc_key)
      else
        # For non-deterministic, use random IV
        Random::Secure.random_bytes(IV_SIZE)
      end
      cipher.iv = iv
      
      # Encrypt
      ciphertext = IO::Memory.new
      ciphertext.write(cipher.update(plaintext_bytes))
      ciphertext.write(cipher.final)
      
      # Build payload without HMAC
      payload_without_hmac = build_payload_without_hmac(iv, ciphertext.to_slice, deterministic)
      
      # Calculate HMAC over the entire payload
      hmac = OpenSSL::HMAC.digest(:sha256, mac_key, payload_without_hmac)
      
      # Combine payload and HMAC
      final_payload = Bytes.new(payload_without_hmac.size + HMAC_SIZE)
      payload_without_hmac.copy_to(final_payload)
      hmac.copy_to(final_payload + payload_without_hmac.size)
      
      final_payload
    rescue ex : OpenSSL::Cipher::Error
      raise EncryptionError.new("Encryption failed: #{ex.message}")
    end
    
    # Decrypt data with the given key
    def self.decrypt(encrypted : Bytes, key : Bytes) : String
      return "" if encrypted.empty?
      
      # Check minimum size
      min_size = 1 + HMAC_SIZE # header + HMAC
      raise DecryptionError.new("Encrypted data too short") if encrypted.size < min_size
      
      # Derive separate keys for encryption and HMAC
      enc_key, mac_key = derive_keys(key)
      
      # Extract HMAC from the end
      payload_size = encrypted.size - HMAC_SIZE
      payload = encrypted[0, payload_size]
      provided_hmac = encrypted[payload_size, HMAC_SIZE]
      
      # Verify HMAC
      expected_hmac = OpenSSL::HMAC.digest(:sha256, mac_key, payload)
      unless secure_compare(provided_hmac, expected_hmac)
        raise DecryptionError.new("HMAC verification failed - data may have been tampered with")
      end
      
      # Parse the encrypted payload
      header, iv, ciphertext = parse_encrypted_payload(payload)
      
      # Verify version
      version = header & 0x7F_u8
      raise DecryptionError.new("Unsupported encryption version: #{version}") unless version == VERSION
      
      # Check if deterministic
      deterministic = (header & Flags::DETERMINISTIC) != 0
      
      # Initialize cipher
      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.decrypt
      cipher.key = enc_key
      cipher.iv = iv
      
      # Decrypt
      plaintext = IO::Memory.new
      plaintext.write(cipher.update(ciphertext))
      plaintext.write(cipher.final)
      
      String.new(plaintext.to_slice)
    rescue ex : OpenSSL::Cipher::Error
      raise DecryptionError.new("Decryption failed: #{ex.message}")
    rescue ex : IndexError
      raise DecryptionError.new("Invalid encrypted data format")
    end
    
    # Derive separate keys for encryption and MAC from a master key
    private def self.derive_keys(master_key : Bytes) : Tuple(Bytes, Bytes)
      # Use HKDF to derive two keys
      info_enc = "encryption"
      info_mac = "authentication"
      
      enc_key = Bytes.new(32)
      mac_key = Bytes.new(32)
      
      # Simple key derivation (in production, use proper HKDF)
      # For now, use HMAC-based derivation
      enc_key_data = OpenSSL::HMAC.digest(:sha256, master_key, info_enc)
      mac_key_data = OpenSSL::HMAC.digest(:sha256, master_key, info_mac)
      
      enc_key_data.copy_to(enc_key)
      mac_key_data.copy_to(mac_key)
      
      {enc_key, mac_key}
    end
    
    # Build payload without HMAC
    private def self.build_payload_without_hmac(iv : Bytes, ciphertext : Bytes, deterministic : Bool) : Bytes
      # Header byte: version (7 bits) + flags (1 bit)
      header = VERSION
      header |= Flags::DETERMINISTIC if deterministic
      
      # Calculate total size (excluding HMAC)
      total_size = 1 + (deterministic ? 0 : IV_SIZE) + ciphertext.size
      
      # Build payload
      payload = Bytes.new(total_size)
      offset = 0
      
      # Write header
      payload[offset] = header
      offset += 1
      
      # Write IV (only for non-deterministic)
      unless deterministic
        iv.copy_to(payload + offset)
        offset += IV_SIZE
      end
      
      # Write ciphertext
      ciphertext.copy_to(payload + offset)
      
      payload
    end
    
    # Parse encrypted payload (without HMAC)
    private def self.parse_encrypted_payload(payload : Bytes) : Tuple(UInt8, Bytes, Bytes)
      offset = 0
      
      # Read header
      header = payload[offset]
      offset += 1
      
      # Check if deterministic
      deterministic = (header & Flags::DETERMINISTIC) != 0
      
      # Read IV
      iv = if deterministic
        # For deterministic, IV will be derived later
        Bytes.empty
      else
        raise DecryptionError.new("Encrypted data too short for IV") if payload.size < offset + IV_SIZE
        iv_bytes = Bytes.new(IV_SIZE)
        payload[offset, IV_SIZE].copy_to(iv_bytes)
        offset += IV_SIZE
        iv_bytes
      end
      
      # Read ciphertext
      ciphertext_size = payload.size - offset
      raise DecryptionError.new("Invalid encrypted data size") if ciphertext_size < 0
      
      ciphertext = Bytes.new(ciphertext_size)
      payload[offset, ciphertext_size].copy_to(ciphertext)
      
      {header, iv, ciphertext}
    end
    
    # Derive deterministic IV from content
    private def self.derive_deterministic_iv(content : Bytes, key : Bytes) : Bytes
      # Use HMAC to derive IV from content
      # This ensures same content always gets same IV
      hmac = OpenSSL::HMAC.digest(:sha256, key, content)
      
      # Take first 16 bytes for IV
      iv = Bytes.new(IV_SIZE)
      hmac[0, IV_SIZE].copy_to(iv)
      iv
    end
    
    # Constant-time comparison for HMAC
    private def self.secure_compare(a : Bytes, b : Bytes) : Bool
      return false unless a.size == b.size
      
      result = 0_u8
      a.size.times do |i|
        result |= a[i] ^ b[i]
      end
      
      result == 0
    end
  end
end