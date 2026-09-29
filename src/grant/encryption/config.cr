module Grant::Encryption
  # Global configuration for encryption
  module Config
    # Whether to support reading unencrypted data during migration
    class_property support_unencrypted_data : Bool = false

    # Compressed attributes (`compress: true`) shorter than this many bytes are
    # stored as they are, since compressing tiny values makes them grow. Matches
    # Active Record's 140.
    class_property compress_threshold : Int32 = 140

    # Whether to log encryption operations (for debugging only!)
    class_property verbose_logging : Bool = false

    # Set the primary encryption key
    def self.primary_key=(key : String)
      KeyProvider.primary_key = key
    end

    # Set the deterministic encryption key
    def self.deterministic_key=(key : String)
      KeyProvider.deterministic_key = key
    end

    # Set the key derivation salt
    def self.key_derivation_salt=(salt : String)
      KeyProvider.key_derivation_salt = salt
    end

    # Sets the primary key and the older keys still accepted for reading, newest
    # first: `primary_keys = [new_key, old_key]`. New writes use the first key;
    # data written under any of them stays readable, so a rotation needs no
    # maintenance window.
    def self.primary_keys=(keys : Array(String)) : Nil
      raise KeyProvider::KeyError.new("primary_keys cannot be empty") if keys.empty?
      KeyProvider.previous_primary_keys = keys[1..].map { |key| KeyProvider.decode_key(key) }
      KeyProvider.primary_key = keys.first
    end

    # Deterministic counterpart of `primary_keys=`.
    def self.deterministic_keys=(keys : Array(String)) : Nil
      raise KeyProvider::KeyError.new("deterministic_keys cannot be empty") if keys.empty?
      KeyProvider.previous_deterministic_keys = keys[1..].map { |key| KeyProvider.decode_key(key) }
      KeyProvider.deterministic_key = keys.first
    end

    # Generate a new random key (for setup)
    def self.generate_key : String
      KeyProvider.generate_key
    end

    # Check if encryption is properly configured
    def self.configured? : Bool
      Encryption.configured?
    end
  end
end
