require "./encryption/key_provider"
require "./encryption/cipher"
require "./encryption/encrypted_attribute"
require "./encryption/config"
require "./encryption/query_extensions"
require "./encryption/migration_helpers"

module Grant::Encryption
  # Configure encryption settings
  def self.configure(&)
    yield Config
  end
  
  # Check if encryption is properly configured
  def self.configured? : Bool
    !KeyProvider.primary_key.nil?
  end
  
  # Encrypt a value for a specific model/attribute
  def self.encrypt(value : String?, model_name : String, attribute_name : String, deterministic : Bool = false) : String?
    return nil if value.nil?
    
    key = KeyProvider.derive_key(model_name, attribute_name, deterministic)
    encrypted_bytes = Cipher.encrypt(value, key, deterministic)
    Base64.strict_encode(encrypted_bytes)
  end
  
  # Decrypt a value for a specific model/attribute
  def self.decrypt(encrypted : String?, model_name : String, attribute_name : String) : String?
    return nil if encrypted.nil? || encrypted.empty?
    
    # Decode the Base64 string to bytes
    begin
      encrypted_bytes = Base64.decode(encrypted)
    rescue e
      raise "Failed to decode Base64: #{e.message}"
    end
    
    # Try both keys in case it was encrypted with either
    begin
      key = KeyProvider.derive_key(model_name, attribute_name, false)
      Cipher.decrypt(encrypted_bytes, key)
    rescue Cipher::DecryptionError
      # Try with deterministic key
      key = KeyProvider.derive_key(model_name, attribute_name, true)
      Cipher.decrypt(encrypted_bytes, key)
    end
  end
  
  # Module to be included in models for encryption support
  module Model
    macro included
      include Grant::Encryption::QueryExtensions
      
      # Track encrypted attributes at the class level
      class_getter encrypted_attributes = {} of String => Grant::Encryption::EncryptedAttribute
      
      # Instance cache for decrypted values
      @encrypted_attribute_cache = {} of String => String?
      
      # Define the cache clearing method
      private def clear_encryption_cache
        @encrypted_attribute_cache.clear
      end
    end
    
    # Macro to define encrypted attributes
    macro encrypts(attribute, deterministic = false)
      # Register callback on first encryption (only once per class)
      {% unless @type.has_constant?("ENCRYPTION_CALLBACK_REGISTERED") %}
        ENCRYPTION_CALLBACK_REGISTERED = true
        after_save :clear_encryption_cache
      {% end %}
      
      # Register the encrypted attribute
      {% 
        attr_name = attribute.id.stringify
      %}
      
      class_getter {{attribute.id}}_encrypted_attribute : Grant::Encryption::EncryptedAttribute = 
        Grant::Encryption::EncryptedAttribute.new(
          self,
          {{attr_name}},
          {{deterministic}}
        )
      
      # Store in registry
      @@encrypted_attributes[{{attr_name}}] = {{attribute.id}}_encrypted_attribute
      
      # Create the encrypted column (stores Base64-encoded string)
      column {{attribute.id}}_encrypted : String?
      
      # Create virtual getter with caching
      def {{attribute.id}} : String?
        # Check cache first
        if @encrypted_attribute_cache.has_key?({{attr_name}})
          return @encrypted_attribute_cache[{{attr_name}}]
        end
        
        encrypted = @{{attribute.id}}_encrypted
        return nil if encrypted.nil?
        
        # Decrypt and cache
        decrypted = Grant::Encryption.decrypt(
          encrypted,
          self.class.name,
          {{attr_name}}
        )
        @encrypted_attribute_cache[{{attr_name}}] = decrypted
        decrypted
      end
      
      # Create virtual setter
      def {{attribute.id}}=(value : String?)
        # Update cache
        @encrypted_attribute_cache[{{attr_name}}] = value
        
        if value.nil?
          @{{attribute.id}}_encrypted = nil
        else
          @{{attribute.id}}_encrypted = Grant::Encryption.encrypt(
            value,
            self.class.name,
            {{attr_name}},
            {{deterministic}}
          )
        end
        
        # Mark as changed for dirty tracking
        # Track the change in dirty tracking
        if responds_to?(:changed_attributes)
          ensure_dirty_tracking_initialized
          # Track encrypted column change
          old_val = @original_attributes.not_nil!["{{attribute.id}}_encrypted"]? || nil
          @changed_attributes.not_nil!["{{attribute.id}}_encrypted"] = {old_val, @{{attribute.id}}_encrypted}
        end
      end
      
      # Add query support for deterministic fields
      {% if deterministic %}
        # Class method for querying encrypted attributes
        def self.where_{{attribute.id}}(value : String)
          encrypted = Grant::Encryption.encrypt(
            value,
            self.name,
            {{attr_name}},
            true
          )
          where({{attribute.id}}_encrypted: encrypted)
        end
        
        # Also support find_by for deterministic fields
        def self.find_by_{{attribute.id}}(value : String)
          where_{{attribute.id}}(value).first
        end
      {% end %}
      
      # Add attribute to the list of attributes for serialization exclusion
      {% if @type.has_method?(:json_options) %}
        json_options(except: [{{attribute.id}}_encrypted])
      {% end %}
    end
  end
end