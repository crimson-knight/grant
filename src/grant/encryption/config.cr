module Grant::Encryption
  # Global configuration for encryption
  module Config
    # Whether to support reading unencrypted data during migration
    class_property support_unencrypted_data : Bool = false
    
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