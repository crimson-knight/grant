module Granite::Encryption
  # Handles the encryption/decryption lifecycle for individual attributes
  class EncryptedAttribute
    getter model_class : Granite::Base.class
    getter attribute_name : String
    getter deterministic : Bool
    getter column_name : String
    
    # Decrypted value cache
    @decrypted_cache = {} of UInt64 => String?
    
    def initialize(@model_class : Granite::Base.class, @attribute_name : String, @deterministic : Bool = false)
      @column_name = "#{attribute_name}_encrypted"
    end
    
    # Encrypt a value
    def encrypt(value : String?) : Bytes?
      return nil if value.nil?
      
      key = derive_key
      encrypted = Cipher.encrypt(value, key, deterministic)
      
      log_operation("encrypt", value.size, encrypted.size) if Config.verbose_logging
      
      encrypted
    end
    
    # Decrypt a value
    def decrypt(encrypted : Bytes?, instance_id : UInt64? = nil) : String?
      return nil if encrypted.nil? || encrypted.empty?
      
      # Check cache if instance_id provided
      if instance_id && @decrypted_cache.has_key?(instance_id)
        return @decrypted_cache[instance_id]
      end
      
      key = derive_key
      decrypted = Cipher.decrypt(encrypted, key)
      
      # Cache if instance_id provided
      @decrypted_cache[instance_id] = decrypted if instance_id
      
      log_operation("decrypt", encrypted.size, decrypted.size) if Config.verbose_logging
      
      decrypted
    rescue ex : Cipher::DecryptionError
      # If supporting unencrypted data, try to interpret as plaintext
      if Config.support_unencrypted_data && encrypted.size > 0
        # Check if it might be plaintext by looking for valid UTF-8
        begin
          plaintext = String.new(encrypted)
          log_operation("decrypt_unencrypted", encrypted.size, plaintext.size) if Config.verbose_logging
          return plaintext
        rescue
          # Not valid UTF-8, re-raise original error
          raise ex
        end
      else
        raise ex
      end
    end
    
    # Clear cache for a specific instance
    def clear_cache(instance_id : UInt64)
      @decrypted_cache.delete(instance_id)
    end
    
    # Clear entire cache
    def clear_cache
      @decrypted_cache.clear
    end
    
    # Encrypt a value for querying (deterministic only)
    def encrypt_for_query(value : String) : Bytes
      raise "Cannot query non-deterministic encrypted attributes" unless deterministic
      
      key = derive_key
      Cipher.encrypt(value, key, true)
    end
    
    # Derive the encryption key for this attribute
    private def derive_key : Bytes
      KeyProvider.derive_key(model_class.name, attribute_name, deterministic)
    end
    
    # Log encryption operations
    private def log_operation(operation : String, input_size : Int32, output_size : Int32)
      Granite::Encryption::Log.debug do
        "#{operation} #{model_class.name}.#{attribute_name}: #{input_size} bytes -> #{output_size} bytes"
      end
    end
  end
  
  # Logger for encryption operations
  Log = ::Log.for("granite.encryption")
end