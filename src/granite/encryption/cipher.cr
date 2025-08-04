require "openssl"
require "random/secure"

module Granite::Encryption
  # Handles encryption and decryption using AES-256-GCM
  class Cipher
    # Cipher algorithm
    ALGORITHM = "aes-256-gcm"
    
    # IV size for GCM mode (96 bits / 12 bytes recommended)
    IV_SIZE = 12
    
    # Authentication tag size (128 bits / 16 bytes)
    AUTH_TAG_SIZE = 16
    
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
    
    # Encrypt data with the given key
    def self.encrypt(plaintext : String, key : Bytes, deterministic : Bool = false) : Bytes
      return Bytes.empty if plaintext.empty?
      
      plaintext_bytes = plaintext.to_slice
      
      # Initialize cipher
      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.encrypt
      cipher.key = key
      
      # Generate or derive IV
      iv = if deterministic
        # For deterministic encryption, derive IV from content
        derive_deterministic_iv(plaintext_bytes, key)
      else
        # For non-deterministic, use random IV
        Random::Secure.random_bytes(IV_SIZE)
      end
      cipher.iv = iv
      
      # Encrypt
      ciphertext = IO::Memory.new
      ciphertext.write(cipher.update(plaintext_bytes))
      ciphertext.write(cipher.final)
      
      # Get authentication tag
      auth_tag = Bytes.new(AUTH_TAG_SIZE)
      LibSSL.evp_cipher_ctx_ctrl(cipher.@ctx, LibSSL::EVP_CTRL_GCM_GET_TAG, AUTH_TAG_SIZE, auth_tag)
      
      # Build result with header
      build_encrypted_payload(iv, ciphertext.to_slice, auth_tag, deterministic)
    rescue ex : OpenSSL::Cipher::Error
      raise EncryptionError.new("Encryption failed: #{ex.message}")
    end
    
    # Decrypt data with the given key
    def self.decrypt(encrypted : Bytes, key : Bytes) : String
      return "" if encrypted.empty?
      
      # Parse the encrypted payload
      header, iv, ciphertext, auth_tag = parse_encrypted_payload(encrypted)
      
      # Verify version
      version = header & 0x7F_u8
      raise DecryptionError.new("Unsupported encryption version: #{version}") unless version == VERSION
      
      # Check if deterministic
      deterministic = (header & Flags::DETERMINISTIC) != 0
      
      # Initialize cipher
      cipher = OpenSSL::Cipher.new(ALGORITHM)
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      
      # Set authentication tag
      LibSSL.evp_cipher_ctx_ctrl(cipher.@ctx, LibSSL::EVP_CTRL_GCM_SET_TAG, AUTH_TAG_SIZE, auth_tag)
      
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
    
    # Build encrypted payload with header
    private def self.build_encrypted_payload(iv : Bytes, ciphertext : Bytes, auth_tag : Bytes, deterministic : Bool) : Bytes
      # Header byte: version (7 bits) + flags (1 bit)
      header = VERSION
      header |= Flags::DETERMINISTIC if deterministic
      
      # Calculate total size
      total_size = 1 + (deterministic ? 0 : IV_SIZE) + ciphertext.size + AUTH_TAG_SIZE
      
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
      offset += ciphertext.size
      
      # Write auth tag
      auth_tag.copy_to(payload + offset)
      
      payload
    end
    
    # Parse encrypted payload
    private def self.parse_encrypted_payload(payload : Bytes) : Tuple(UInt8, Bytes, Bytes, Bytes)
      raise DecryptionError.new("Encrypted data too short") if payload.size < 1 + AUTH_TAG_SIZE
      
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
      
      # Calculate ciphertext size
      ciphertext_size = payload.size - offset - AUTH_TAG_SIZE
      raise DecryptionError.new("Invalid encrypted data size") if ciphertext_size < 0
      
      # Read ciphertext
      ciphertext = Bytes.new(ciphertext_size)
      payload[offset, ciphertext_size].copy_to(ciphertext)
      offset += ciphertext_size
      
      # Read auth tag
      auth_tag = Bytes.new(AUTH_TAG_SIZE)
      payload[offset, AUTH_TAG_SIZE].copy_to(auth_tag)
      
      {header, iv, ciphertext, auth_tag}
    end
    
    # Derive deterministic IV from content
    private def self.derive_deterministic_iv(content : Bytes, key : Bytes) : Bytes
      # Use HMAC to derive IV from content
      # This ensures same content always gets same IV
      hmac = OpenSSL::HMAC.digest(:sha256, key, content)
      
      # Take first 12 bytes for IV
      iv = Bytes.new(IV_SIZE)
      hmac[0, IV_SIZE].copy_to(iv)
      iv
    end
  end
end

# Add LibSSL bindings for GCM
lib LibSSL
  EVP_CTRL_GCM_SET_TAG = 0x11
  EVP_CTRL_GCM_GET_TAG = 0x10
  
  fun evp_cipher_ctx_ctrl(ctx : Void*, type : Int32, arg : Int32, ptr : Void*) : Int32
end