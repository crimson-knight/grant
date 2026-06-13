require "./encryption/key_provider"
require "./encryption/cipher"
require "./encryption/encrypted_attribute"
require "./encryption/config"
require "./encryption/query_extensions"
require "./encryption/migration_helpers"

# Transparent at-rest encryption for string attributes, in the style of Rails'
# Active Record Encryption.
#
# Declaring `encrypts :ssn` on a model swaps the plaintext `ssn` accessors for a
# pair that encrypt on write and decrypt on read, storing the ciphertext in a
# generated `ssn_encrypted` column. The plaintext never touches the database.
#
# ### Cipher
#
# Values are sealed with **AES-256-CBC** and authenticated with **HMAC-SHA256**
# (Encrypt-then-MAC). This is *not* AES-GCM — GCM's tag API is not available in
# Crystal's OpenSSL bindings, so an explicit HMAC provides the integrity check.
# The ciphertext is Base64-encoded before being written to the column.
#
# ### Deterministic vs non-deterministic
#
# * **Non-deterministic** (the default): a random IV is generated per write, so
#   encrypting the same plaintext twice yields different ciphertext. Most secure,
#   but the column **cannot be queried** by value.
# * **Deterministic** (`encrypts :email, deterministic: true`): the IV is derived
#   from the plaintext, so equal plaintexts produce equal ciphertext. This enables
#   exact-match lookups via the generated `where_<attr>` / `find_by_<attr>` class
#   methods, at the cost of leaking value equality.
#
# ### Setup
#
# Configure the keys once at boot (see `Grant::Encryption.configure`). Generate
# keys with `Grant::Encryption::Config.generate_key` (a Base64-encoded 32-byte
# key). Deterministic attributes additionally require `deterministic_key`.
#
# ```
# require "grant/encryption"
#
# Grant::Encryption.configure do |config|
#   config.primary_key = ENV["GRANT_PRIMARY_KEY"]
#   config.deterministic_key = ENV["GRANT_DETERMINISTIC_KEY"]
#   config.key_derivation_salt = ENV["GRANT_KEY_SALT"]
# end
#
# class User < Grant::Base
#   column id : Int64, primary: true
#   encrypts :ssn                        # non-deterministic, not queryable
#   encrypts :email, deterministic: true # queryable by exact value
# end
#
# user = User.new
# user.ssn = "123-45-6789" # encrypted on assignment; ssn_encrypted is ciphertext
# user.save
# user.ssn # => "123-45-6789" (decrypted transparently)
#
# # deterministic attributes can be looked up by value:
# User.find_by_email("alice@example.com")
# ```
module Grant::Encryption
  # Configures the global encryption settings by yielding `Grant::Encryption::Config`.
  #
  # Call once at application boot, before any encrypted attribute is read or
  # written. At minimum set `primary_key`; set `deterministic_key` too if any
  # attribute uses `deterministic: true`. Keys are Base64-encoded 32-byte strings
  # (generate with `Config.generate_key`).
  #
  # ```
  # Grant::Encryption.configure do |config|
  #   config.primary_key = ENV["GRANT_PRIMARY_KEY"]
  #   config.deterministic_key = ENV["GRANT_DETERMINISTIC_KEY"]
  #   config.key_derivation_salt = ENV["GRANT_KEY_SALT"]
  # end
  # ```
  def self.configure(&)
    yield Config
  end

  # Returns `true` once a primary encryption key has been configured.
  #
  # Useful as a boot-time guard before touching encrypted attributes (reading or
  # writing one without a configured key raises `KeyProvider::KeyError`).
  #
  # ```
  # Grant::Encryption.configure { |c| c.primary_key = Grant::Encryption::Config.generate_key }
  # Grant::Encryption.configured? # => true
  # ```
  def self.configured? : Bool
    !KeyProvider.primary_key.nil?
  end

  # Encrypts *value* for the `model_name`/`attribute_name` pair and returns the
  # Base64-encoded ciphertext, or `nil` when *value* is `nil`.
  #
  # The key is derived per model+attribute via HKDF, so ciphertext from one
  # attribute cannot be decrypted as another. Pass `deterministic: true` to derive
  # the IV from the content (equal plaintext ⇒ equal ciphertext, queryable). This
  # is the primitive the generated setters call; most code uses `encrypts` instead.
  #
  # ```
  # Grant::Encryption.configure { |c| c.primary_key = Grant::Encryption::Config.generate_key }
  # sealed = Grant::Encryption.encrypt("123-45-6789", "User", "ssn")
  # sealed # => Base64 ciphertext (String), differs each call (non-deterministic)
  # ```
  def self.encrypt(value : String?, model_name : String, attribute_name : String, deterministic : Bool = false) : String?
    return nil if value.nil?

    key = KeyProvider.derive_key(model_name, attribute_name, deterministic)
    encrypted_bytes = Cipher.encrypt(value, key, deterministic)
    Base64.strict_encode(encrypted_bytes)
  end

  # Decrypts the Base64-encoded *encrypted* ciphertext for the
  # `model_name`/`attribute_name` pair, returning the plaintext, or `nil` when
  # *encrypted* is `nil`/empty.
  #
  # Tries the non-deterministic key first, then the deterministic key, so a single
  # call decrypts a value regardless of which mode wrote it (HMAC verification
  # distinguishes them). Raises if the HMAC check fails (tampering) or the key is
  # wrong. This is the primitive the generated getters call.
  #
  # ```
  # Grant::Encryption.configure { |c| c.primary_key = Grant::Encryption::Config.generate_key }
  # sealed = Grant::Encryption.encrypt("hello", "User", "note").not_nil!
  # Grant::Encryption.decrypt(sealed, "User", "note") # => "hello"
  # ```
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

  # Encryption support mixed into every `Grant::Base` model. Provides the
  # `encrypts` macro and the per-instance decrypted-value cache. You normally do
  # not include this directly — `Grant::Base` already does.
  module Model
    macro included
      include Grant::Encryption::QueryExtensions

      # Track encrypted attributes at the class level
      class_getter encrypted_attributes = {} of String => Grant::Encryption::EncryptedAttribute

      # Instance cache for decrypted values.
      # Declared nilable (with lazy initialization in `encrypted_attribute_cache`
      # below) rather than carrying a default value so that `YAML::Serializable` /
      # `JSON::Serializable`'s auto-generated deserialization initializer — included
      # on the abstract `Grant::Base` — does not report it as uninitialized for
      # `Grant::Base+`. The ignore annotations also keep this transient cache out
      # of (de)serialized output. See issues #39/#41.
      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @encrypted_attribute_cache : Hash(String, String?)?

      protected def encrypted_attribute_cache : Hash(String, String?)
        @encrypted_attribute_cache ||= {} of String => String?
      end

      # Define the cache clearing method
      private def clear_encryption_cache
        encrypted_attribute_cache.clear
      end
    end

    # Declares *attribute* as a transparently encrypted string column.
    #
    # Generates, for `encrypts :ssn`:
    #
    # * a `ssn_encrypted : String?` column — the only thing stored in the DB
    #   (Base64 ciphertext); plaintext is never persisted;
    # * `#ssn : String?` — decrypts on read (cached per instance until the next
    #   save) and returns the plaintext;
    # * `#ssn=(value : String?)` — encrypts on write into `ssn_encrypted` and
    #   records the change for dirty tracking.
    #
    # Pass `deterministic: true` to make equal plaintexts encrypt to equal
    # ciphertext. That additionally generates two class methods for exact-match
    # lookup:
    #
    # * `.where_ssn(value : String)` — a query scoped to the matching ciphertext;
    # * `.find_by_ssn(value : String)` — the first matching record (or `nil`).
    #
    # Non-deterministic attributes use a random IV and therefore **cannot** be
    # queried by value — only decrypted after loading by primary key or another
    # column. Requires `Grant::Encryption.configure` to have run with a
    # `primary_key` (and `deterministic_key` for deterministic attributes).
    #
    # ```
    # Grant::Encryption.configure do |c|
    #   c.primary_key = ENV["GRANT_PRIMARY_KEY"]
    #   c.deterministic_key = ENV["GRANT_DETERMINISTIC_KEY"]
    # end
    #
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   encrypts :ssn                        # non-deterministic
    #   encrypts :email, deterministic: true # deterministic, queryable
    # end
    #
    # u = User.new
    # u.ssn = "123-45-6789"
    # u.email = "alice@example.com"
    # u.save
    #
    # u.ssn                                        # => "123-45-6789" (decrypted)
    # User.find_by_email("alice@example.com")      # => the saved user
    # User.where_email("alice@example.com").select # => Array(User)
    # ```
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
        if encrypted_attribute_cache.has_key?({{attr_name}})
          return encrypted_attribute_cache[{{attr_name}}]
        end
        
        encrypted = @{{attribute.id}}_encrypted
        return nil if encrypted.nil?
        
        # Decrypt and cache
        decrypted = Grant::Encryption.decrypt(
          encrypted,
          self.class.name,
          {{attr_name}}
        )
        encrypted_attribute_cache[{{attr_name}}] = decrypted
        decrypted
      end
      
      # Create virtual setter
      def {{attribute.id}}=(value : String?)
        # Update cache
        encrypted_attribute_cache[{{attr_name}}] = value
        
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
