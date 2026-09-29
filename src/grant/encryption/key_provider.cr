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
    @@derived_keys_mutex = Mutex.new

    class KeyError < Grant::ErrorBase
    end

    # One primary/deterministic key pair with the salt it was derived under.
    # Decryption tries the current pair first and then each previous pair, so a
    # rotation can read data written under either without a maintenance window.
    class KeySet
      getter primary_key : Bytes?
      getter deterministic_key : Bytes?
      getter salt : String

      def initialize(@primary_key : Bytes?, @deterministic_key : Bytes?, @salt : String)
      end
    end

    # Bumped whenever keys or the salt change, so caches built from them (the
    # derived keys here and each attribute's previous-scheme keys) can tell
    # they are stale.
    @@generation = 0

    def self.generation : Int32
      @@derived_keys_mutex.synchronize { @@generation }
    end

    @@previous_primary_keys = [] of Bytes
    @@previous_deterministic_keys = [] of Bytes
    @@previous_key_sets = [] of KeySet

    # Primary encryption key
    @@primary_key : Bytes? = nil

    def self.primary_key : Bytes?
      @@derived_keys_mutex.synchronize { @@primary_key }
    end

    def self.primary_key=(key : Bytes?)
      @@derived_keys_mutex.synchronize do
        @@primary_key = key
        @@derived_keys.clear
        rebuild_previous_key_sets
      end
    end

    # Deterministic encryption key (separate for security)
    @@deterministic_key : Bytes? = nil

    def self.deterministic_key : Bytes?
      @@derived_keys_mutex.synchronize { @@deterministic_key }
    end

    def self.deterministic_key=(key : Bytes?)
      @@derived_keys_mutex.synchronize do
        @@deterministic_key = key
        @@derived_keys.clear
        rebuild_previous_key_sets
      end
    end

    # Key derivation salt
    @@key_derivation_salt : String = DEFAULT_SALT

    def self.key_derivation_salt : String
      @@derived_keys_mutex.synchronize { @@key_derivation_salt }
    end

    def self.key_derivation_salt=(salt : String)
      @@derived_keys_mutex.synchronize do
        @@key_derivation_salt = salt
        @@derived_keys.clear
        rebuild_previous_key_sets
      end
    end

    # Load primary key from base64-encoded string
    def self.primary_key=(key : String)
      self.primary_key = decode_key(key)
    end

    # Load deterministic key from base64-encoded string
    def self.deterministic_key=(key : String)
      self.deterministic_key = decode_key(key)
    end

    # Older primary keys, newest first. Data written under them stays readable;
    # new writes always use `primary_key`.
    def self.previous_primary_keys : Array(Bytes)
      @@derived_keys_mutex.synchronize { @@previous_primary_keys.dup }
    end

    def self.previous_primary_keys=(keys : Array(Bytes))
      @@derived_keys_mutex.synchronize do
        @@previous_primary_keys = keys.dup
        @@derived_keys.clear
        rebuild_previous_key_sets
      end
    end

    # Older deterministic keys, newest first. See `previous_primary_keys`.
    def self.previous_deterministic_keys : Array(Bytes)
      @@derived_keys_mutex.synchronize { @@previous_deterministic_keys.dup }
    end

    def self.previous_deterministic_keys=(keys : Array(Bytes))
      @@derived_keys_mutex.synchronize do
        @@previous_deterministic_keys = keys.dup
        @@derived_keys.clear
        rebuild_previous_key_sets
      end
    end

    # The previous keys zipped into pairs, newest first, each with the current
    # salt. Rebuilt whenever a key or the salt changes; callers hold the result
    # and compare `KeyProvider.generation` to notice a change.
    def self.previous_key_sets : Array(KeySet)
      @@derived_keys_mutex.synchronize { @@previous_key_sets }
    end

    # Callers must hold `@@derived_keys_mutex`.
    private def self.rebuild_previous_key_sets : Nil
      @@generation += 1
      count = Math.max(@@previous_primary_keys.size, @@previous_deterministic_keys.size)
      @@previous_key_sets = Array(KeySet).new(count) do |index|
        KeySet.new(@@previous_primary_keys[index]?, @@previous_deterministic_keys[index]?, @@key_derivation_salt)
      end
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

      @@derived_keys_mutex.synchronize do
        if cached_key = @@derived_keys[cache_key]?
          cached_key
        else
          master_key = deterministic ? @@deterministic_key : @@primary_key
          key = master_key || raise KeyError.new(
            deterministic ? "Deterministic encryption key not configured. Set Grant::Encryption::KeyProvider.deterministic_key" : "Primary encryption key not configured. Set Grant::Encryption::KeyProvider.primary_key"
          )
          salt = @@key_derivation_salt
          info = "#{DERIVE_INFO_PREFIX}.#{model_name}.#{attribute_name}"
          derived_key = hkdf(secret: key, salt: salt, info: info, length: KEY_SIZE)
          @@derived_keys[cache_key] = derived_key
        end
      end
    end

    # The key for one attribute under *key_set*, or `nil` when that set has no
    # key of the requested kind. Not cached here; callers that decrypt often keep
    # the result (see `EncryptedAttribute`).
    def self.derive_key_from_set?(model_name : String, attribute_name : String, deterministic : Bool, key_set : KeySet) : Bytes?
      master_key = deterministic ? key_set.deterministic_key : key_set.primary_key
      return nil unless master_key

      hkdf(
        secret: master_key,
        salt: key_set.salt,
        info: "#{DERIVE_INFO_PREFIX}.#{model_name}.#{attribute_name}",
        length: KEY_SIZE
      )
    end

    # Derives a key from explicit configuration without reading or changing the
    # process-wide key settings or their cache. Used by migrations that need to
    # read old ciphertext while application fibers continue using current keys.
    def self.derive_key_with_keys(
      model_name : String,
      attribute_name : String,
      deterministic : Bool,
      primary_key : Bytes?,
      deterministic_key : Bytes?,
      salt : String,
    ) : Bytes
      master_key = if deterministic
                     deterministic_key || raise KeyError.new("Deterministic encryption key not configured")
                   else
                     primary_key || raise KeyError.new("Primary encryption key not configured")
                   end

      hkdf(
        secret: master_key,
        salt: salt,
        info: "#{DERIVE_INFO_PREFIX}.#{model_name}.#{attribute_name}",
        length: KEY_SIZE
      )
    end

    # Clear the key cache (useful for testing or key rotation)
    def self.clear_cache
      @@derived_keys_mutex.synchronize { @@derived_keys.clear }
    end

    # Decode a base64-encoded key
    def self.decode_key(encoded : String) : Bytes
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
