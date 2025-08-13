require "openssl"
require "base64"

module Grant::Encryption
  # Manages encryption keys and key derivation for encrypted attributes
  class KeyProvider
    # HKDF info prefix for key derivation
    DERIVE_INFO_PREFIX = "grant-encryption"
    
    # Key size in bytes (256 bits for AES-256)
    KEY_SIZE = 32
    
    # Default key derivation salt
    DEFAULT_SALT = "grant-encryption-v1"
    
    # Cache for derived keys
    @@derived_keys = {} of String => Bytes
    
    class KeyError < Exception
    end
    
    # Primary encryption key
    class_property primary_key : Bytes? = nil
    
    # Deterministic encryption key (separate for security)
    class_property deterministic_key : Bytes? = nil
    
    # Key derivation salt
    class_property key_derivation_salt : String = DEFAULT_SALT
    
    # Load primary key from base64-encoded string
    def self.primary_key=(key : String)
      @@primary_key = decode_key(key)
    end
    
    # Load deterministic key from base64-encoded string
    def self.deterministic_key=(key : String)
      @@deterministic_key = decode_key(key)
    end
    
    # Get the primary encryption key
    def self.primary_key! : Bytes
      primary_key || raise KeyError.new("Primary encryption key not configured. Set Grant::Encryption::KeyProvider.primary_key")
    end
    
    # Get the deterministic encryption key
    def self.deterministic_key! : Bytes
      deterministic_key || raise KeyError.new("Deterministic encryption key not configured. Set Grant::Encryption::KeyProvider.deterministic_key")
    end
    
    # Generate a random key
    def self.generate_key : String
      Base64.strict_encode(Random::Secure.random_bytes(KEY_SIZE))
    end
    
    # Derive a key for a specific model and attribute
    def self.derive_key(model_name : String, attribute_name : String, deterministic : Bool = false) : Bytes
      cache_key = "#{model_name}.#{attribute_name}.#{deterministic}"
      
      # Return cached key if available
      return @@derived_keys[cache_key] if @@derived_keys.has_key?(cache_key)
      
      # Select master key based on mode
      master_key = deterministic ? deterministic_key! : primary_key!
      
      # Derive key using HKDF
      info = "#{DERIVE_INFO_PREFIX}.#{model_name}.#{attribute_name}"
      derived_key = hkdf(
        secret: master_key,
        salt: key_derivation_salt,
        info: info,
        length: KEY_SIZE
      )
      
      # Cache the derived key
      @@derived_keys[cache_key] = derived_key
      
      derived_key
    end
    
    # Clear the key cache (useful for testing or key rotation)
    def self.clear_cache
      @@derived_keys.clear
    end
    
    # Decode a base64-encoded key
    private def self.decode_key(encoded : String) : Bytes
      decoded = Base64.decode(encoded)
      raise KeyError.new("Invalid key size: expected #{KEY_SIZE} bytes, got #{decoded.size}") unless decoded.size == KEY_SIZE
      decoded
    rescue ex : Base64::Error
      raise KeyError.new("Invalid base64-encoded key: #{ex.message}")
    end
    
    # HKDF (HMAC-based Key Derivation Function) implementation
    # Based on RFC 5869
    private def self.hkdf(secret : Bytes, salt : String, info : String, length : Int32) : Bytes
      # Use SHA-256 for HKDF
      hash_len = 32 # SHA-256 output size
      
      # Step 1: Extract
      salt_bytes = salt.to_slice
      prk = OpenSSL::HMAC.digest(:sha256, salt_bytes, secret)
      
      # Step 2: Expand
      n = (length.to_f / hash_len).ceil.to_i
      okm = Bytes.new(n * hash_len)
      previous = Bytes.empty
      
      n.times do |i|
        data = IO::Memory.new
        data.write(previous)
        data.write(info.to_slice)
        data.write_byte((i + 1).to_u8)
        
        previous = OpenSSL::HMAC.digest(:sha256, prk, data.to_slice)
        previous.copy_to(okm + (i * hash_len))
      end
      
      # Return only the requested length
      okm[0, length]
    end
  end
end