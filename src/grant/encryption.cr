require "./encryption/key_provider"
require "./encryption/cipher"
require "./encryption/encrypted_attribute"
require "./encryption/config"
require "./encryption/scheme"
require "./encryption/context"
require "./encryption/serializer"
require "./encryption/sealed"
require "./encryption/compression"
require "./encryption/log_filter"
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
  def self.encrypt(value : String, model_name : String, attribute_name : String, deterministic : Bool = false) : String
    key = KeyProvider.derive_key(model_name, attribute_name, deterministic)
    encrypted_bytes = Cipher.encrypt(value, key, deterministic)
    Base64.strict_encode(encrypted_bytes)
  end

  def self.encrypt(value : String?, model_name : String, attribute_name : String, deterministic : Bool = false) : String?
    return if value.nil?
    encrypt(value, model_name, attribute_name, deterministic)
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
    return if encrypted.nil? || encrypted.empty?

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

  # :nodoc:
  def self.encrypt_with_keys(
    value : String,
    model_name : String,
    attribute_name : String,
    deterministic : Bool,
    primary_key : Bytes?,
    deterministic_key : Bytes?,
    salt : String,
  ) : String
    key = KeyProvider.derive_key_with_keys(
      model_name, attribute_name, deterministic, primary_key, deterministic_key, salt
    )
    Base64.strict_encode(Cipher.encrypt(value, key, deterministic))
  end

  # :nodoc:
  def self.decrypt_with_keys(
    encrypted : String,
    model_name : String,
    attribute_name : String,
    primary_key : Bytes?,
    deterministic_key : Bytes?,
    salt : String,
  ) : String
    encrypted_bytes = Base64.decode(encrypted)
    last_error = nil.as(Cipher::DecryptionError?)

    if primary_key
      begin
        key = KeyProvider.derive_key_with_keys(model_name, attribute_name, false, primary_key, deterministic_key, salt)
        return Cipher.decrypt(encrypted_bytes, key)
      rescue ex : Cipher::DecryptionError
        last_error = ex
      end
    end

    if deterministic_key
      begin
        key = KeyProvider.derive_key_with_keys(model_name, attribute_name, true, primary_key, deterministic_key, salt)
        return Cipher.decrypt(encrypted_bytes, key)
      rescue ex : Cipher::DecryptionError
        last_error = ex
      end
    end

    raise last_error if last_error
    raise KeyProvider::KeyError.new("No encryption key was provided")
  rescue ex : Base64::Error
    raise Cipher::DecryptionError.new("Failed to decode Base64: #{ex.message}")
  end

  # Encryption support mixed into every `Grant::Base` model. Provides the
  # `encrypts` macro, the record helpers and the per-instance decrypted-value
  # cache. You normally do not include this directly — `Grant::Base` already does.
  module Model
    module ClassMethods
      def encrypted_attributes : Hash(String, Grant::Encryption::EncryptedAttribute)
        Grant::Encryption::EncryptedAttributeRegistry.for(name)
      end

      # The encrypted attribute *field* names, if it is one. Used by the query
      # builder to encrypt values in `where(email: ...)`; a plain hash probe,
      # with no copy of the registry.
      def encrypted_query_attribute(field : String) : Grant::Encryption::EncryptedAttribute?
        Grant::Encryption::EncryptedAttributeRegistry.lookup(name, field)
      end
    end

    # Whether *attribute_name* is declared with `encrypts` and currently holds
    # an encrypted payload. For a transparent attribute this is the value that
    # would be written, since the loaded record keeps the plaintext.
    #
    # ```
    # user.encrypted_attribute?(:email) # => true
    # user.encrypted_attribute?(:name)  # => false
    # ```
    def encrypted_attribute?(attribute_name : Symbol | String) : Bool
      return false unless self.class.encrypted_query_attribute(attribute_name.to_s)
      stored = ciphertext_for(attribute_name)
      return false if stored.nil? || stored.empty?

      Cipher.encrypted_payload?(Base64.decode(stored))
    rescue Base64::Error
      false
    end

    # The ciphertext of *attribute_name* as the database holds it (or would
    # hold it after the next save). Non-deterministic attributes produce a new
    # ciphertext each time it is computed for a transparent column.
    #
    # ```
    # user.ciphertext_for(:email) # => "AQ3x..." (Base64)
    # ```
    def ciphertext_for(attribute_name : Symbol | String) : String?
      encrypted_attribute_named(attribute_name).ciphertext_for(self)
    end

    # Rewrites every encrypted attribute of this persisted record with fresh
    # ciphertext (for example after enabling encryption on data read through
    # `support_unencrypted_data`). Skips validations, callbacks and timestamps.
    def encrypt : Bool
      rewrite_encrypted_columns(plaintext: false)
    end

    # Writes the plaintext of every transparent encrypted attribute back to its
    # column. The counterpart of `#encrypt`, for backing out of encryption.
    # Attributes declared in the `<attr>_encrypted` form have no plaintext
    # column and are left alone.
    def decrypt : Bool
      rewrite_encrypted_columns(plaintext: true)
    end

    # Opens every lazily decrypted attribute still sealed on this record. Called
    # before a whole-record serialization.
    #
    # :nodoc:
    def __unseal_lazy_attributes : Nil
      self.class.encrypted_attributes.each_value(&.unseal(self))
    end

    private def encrypted_attribute_named(attribute_name : Symbol | String) : Grant::Encryption::EncryptedAttribute
      self.class.encrypted_query_attribute(attribute_name.to_s) ||
        raise ArgumentError.new("#{self.class.name}##{attribute_name} is not an encrypted attribute")
    end

    private def rewrite_encrypted_columns(plaintext : Bool) : Bool
      raise ArgumentError.new("Cannot rewrite encrypted columns of a new record") unless persisted?

      assignments = [] of Tuple(String, Grant::Columns::Type)
      self.class.encrypted_attributes.each_value do |attribute|
        text = attribute.plaintext_for(self)
        if plaintext
          next unless attribute.transparent?
          assignments << {attribute.column_name, text}
        else
          assignments << {attribute.column_name, text.try { |value| attribute.seal(value) }}
        end
      end
      return true if assignments.empty?

      primary_name = self.class.primary_name
      self.class.where(primary_name, :eq, read_attribute(primary_name)).update_all(assignments) > 0
    end

    macro included
      include Grant::Encryption::QueryExtensions
      extend ClassMethods

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

    # Declares *attribute* as a transparently encrypted attribute.
    #
    # There are two forms.
    #
    # **Typed, same-name column** — `encrypts email : String`. The value lives,
    # encrypted, in the column named `email`; the accessor has the declared type
    # (`String`, an integer or float type, `Bool`, `Time`, `JSON::Any`, or a
    # `JSON::Serializable` type) and the attribute is always nilable.
    # `where(email: "a@b.c")` is rewritten to compare the ciphertext for
    # deterministic attributes. The column must be text.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   encrypts email : String, deterministic: true, ignore_case: true
    #   encrypts balance : Int64
    # end
    #
    # User.where(email: "Ada@Example.com") # matches ada@example.com too
    # ```
    #
    # **Symbol, `<attr>_encrypted` column** — `encrypts :ssn`, the original
    # String-only form: a generated `ssn_encrypted : String?` column holds the
    # ciphertext and `#ssn` / `#ssn=` decrypt and encrypt around it. Existing
    # models and data keep working unchanged.
    #
    # Options:
    #
    # * `deterministic: true` — equal plaintexts encrypt to equal ciphertext, so
    #   the attribute can be matched by value (`where(email: ...)`,
    #   `where_email`, `find_by_email`), at the cost of leaking equality.
    # * `downcase: true` — the value is stored and read back lower-cased.
    # * `ignore_case: true` — lookups ignore case while `#email` still returns
    #   the original. Needs `deterministic: true`, the typed form and a text
    #   `original_<attr>` column, which stores the original case (encrypted).
    # * `compress: true` — zlib-compress values of at least `compress_threshold`
    #   bytes (default `Config.compress_threshold`, 140) before encrypting.
    # * `previous: [{deterministic: true, key: old_key, salt: old_salt}]` — older
    #   schemes tried, newest first, when a stored value does not decrypt with
    #   the current keys. `key` is Base64 and is the deterministic key when the
    #   scheme is deterministic.
    # * `lazy: true` — typed `String` attributes only. The value is not
    #   decrypted when a row loads but on first read (and then kept), so reading
    #   rows that never touch the attribute costs no decryption, and an
    #   undecryptable value fails at the read instead of at the load. The
    #   attribute's readers, `inspect`, `attributes`, `to_json`/`to_yaml`,
    #   `reload` and `dup` all see a consistent value. A full-row `save` reads
    #   every encrypted attribute. Default `false`.
    # * `support_unencrypted_data: true` — read values that were stored before
    #   encryption was enabled as they are. Overrides the global setting for
    #   this attribute; deterministic lookups then also match the plaintext.
    macro encrypts(attribute, deterministic = false, downcase = false, ignore_case = false, compress = false, compress_threshold = nil, previous = nil, support_unencrypted_data = nil, lazy = nil)
      {% typed = attribute.is_a?(TypeDeclaration) %}
      {% attr = typed ? attribute.var.id : attribute.id %}
      {% attr_name = attr.stringify %}
      {% base = nil %}
      {% if typed %}
        {% attr_type = attribute.type %}
        {% base = attr_type.is_a?(Union) ? attr_type.types.reject(&.resolve.nilable?).first : attr_type %}
      {% end %}
      {% if ignore_case && !deterministic %}
        {% raise "encrypts #{attr_name}: ignore_case: true requires deterministic: true" %}
      {% end %}
      {% if ignore_case && !typed %}
        {% raise "encrypts #{attr_name}: ignore_case: true needs the typed form, `encrypts #{attr_name} : String`" %}
      {% end %}
      {% if (downcase || ignore_case) && typed && base.resolve != String %}
        {% raise "encrypts #{attr_name}: downcase: and ignore_case: apply to String attributes only" %}
      {% end %}
      {% if lazy && !typed %}
        {% raise "encrypts #{attr_name}: lazy: applies to the typed form, `encrypts #{attr_name} : String`" %}
      {% end %}
      {% if lazy && typed && base.resolve != String %}
        {% raise "encrypts #{attr_name}: lazy: true applies to String attributes only; other types are decrypted when the row loads" %}
      {% end %}
      {% lazy_on = typed && lazy == true %}
      {% if previous && !previous.is_a?(ArrayLiteral) %}
        {% raise "encrypts #{attr_name}: previous: must be an array literal of schemes" %}
      {% end %}

      # Register the encrypted attribute
      class_getter {{attr}}_encrypted_attribute : Grant::Encryption::EncryptedAttribute =
        Grant::Encryption::EncryptedAttribute.new(
          self,
          {{attr_name}},
          {{deterministic}},
          {% if typed %}
            ->(record : Grant::Base, value : String?) do
              record.as({{@type}}).{{attr}} = value.try { |text| Grant::Encryption::Serializer.load(text, {{base}}) }
              nil
            end,
            column_name: {{attr_name}},
          {% else %}
            ->(record : Grant::Base, value : String?) do
              record.as({{@type}}).{{attr}} = value
            end,
          {% end %}
          options: Grant::Encryption::EncryptedAttribute::Options.new(
            downcase: {{downcase ? true : false}},
            ignore_case: {{ignore_case ? true : false}},
            compress: {{compress ? true : false}},
            compress_threshold: {{compress_threshold}},
            support_unencrypted_data: {{support_unencrypted_data}},
            previous: [
              {% if previous %}
                {% for scheme in previous %}
                  Grant::Encryption::Scheme.build(
                    deterministic: {{scheme[:deterministic] ? true : false}},
                    key: {{scheme[:key]}},
                    salt: {{scheme[:salt]}}
                  ),
                {% end %}
              {% end %}
            ] of Grant::Encryption::Scheme,
            transparent: {{typed}},
            type_name: {{typed ? base.stringify : "String"}}
          ),
          {% if lazy_on %}
            unsealer: ->(record : Grant::Base) do
              record.as({{@type}}).__unseal_{{attr}}
              nil
            end,
          {% end %}
          plain_reader: ->(record : Grant::Base) do
            {% if typed %}
              record.as({{@type}}).{{attr}}.try { |value| Grant::Encryption::Serializer.dump(value) }
            {% else %}
              record.as({{@type}}).{{attr}}
            {% end %}
          end,
          {% if typed %}
            stored_reader: nil
          {% else %}
            stored_reader: ->(record : Grant::Base) do
              record.read_attribute({{attr_name + "_encrypted"}}).as?(String)
            end
          {% end %}
        )

      # Store in registry
      Grant::Encryption::EncryptedAttributeRegistry.register(
        self.name,
        {{attr_name}},
        {{attr}}_encrypted_attribute
      )
      Grant::Encryption::LogFilter.track(self)

      {% if typed %}
        # Converts between the attribute's type and the ciphertext column.
        module {{attr_name.camelcase.id}}EncryptionConverter
          extend self

          def to_db(value : {{base}}?) : Grant::Columns::Type
            return nil if value.nil?
            {% if lazy_on %}
              # Still sealed: the column already holds this ciphertext.
              return Grant::Encryption::Sealed.stored(value) if Grant::Encryption::Sealed.sealed?(value)
            {% end %}
            {{@type}}.{{attr}}_encrypted_attribute.seal(Grant::Encryption::Serializer.dump(value))
          end

          def from_rs(result : ::DB::ResultSet) : {{base}}?
            stored = result.read(String?)
            return nil if stored.nil?
            {% if lazy_on %}
              # Inside `without_encryption` the raw text is the value, as ever.
              return Grant::Encryption::Sealed.wrap(stored) unless Grant::Encryption.current_context.encryption_disabled?
            {% end %}
            {% if base.resolve != String %}
              if Grant::Encryption.current_context.encryption_disabled?
                raise Grant::Encryption::UnsupportedTypeError.new("{{@type}}.{{attr_name.id}} is a {{base}} and cannot be read raw inside without_encryption")
              end
            {% end %}
            Grant::Encryption::Serializer.load({{@type}}.{{attr}}_encrypted_attribute.open(stored), {{base}})
          end
        end

        {% if ignore_case %}
          encrypts {{("original_" + attr_name).id}} : String?{{ ", lazy: true".id if lazy_on }}
        {% end %}

        column {{attr}} : {{base}}?, converter: ::{{@type}}::{{attr_name.camelcase.id}}EncryptionConverter, column_type: "TEXT"

        {% if downcase %}
          def {{attr}}=(value : String?)
            previous_def(value.try(&.downcase))
          end
        {% end %}

        {% if lazy_on %}
          # Opens the stored ciphertext on first use and keeps the plaintext. Keys
          # pinned by `with_context` apply at the time of the read; a record
          # loaded outside `without_encryption` reads as plaintext inside it, as
          # an eagerly decrypted one does.
          # :nodoc:
          def __unseal_{{attr}} : String?
            current = @{{attr}}
            return current unless current && Grant::Encryption::Sealed.sealed?(current)

            @{{attr}} = self.class.{{attr}}_encrypted_attribute.open_with_index(Grant::Encryption::Sealed.stored(current))[0]
          end

          def {{attr}} : String?
            __unseal_{{attr}}
          end

          def {{attr}}? : String?
            __unseal_{{attr}}
          end

          def {{attr}}! : String
            __unseal_{{attr}} || raise NilAssertionError.new({{@type.name.stringify}} + "#" + {{attr_name}} + " cannot be nil")
          end

          def {{attr}}_in_database : String?
            __unseal_{{attr}}
            previous_def
          end

          def {{attr}}_previously_was : String?
            __unseal_{{attr}}
            previous_def
          end

          def {{attr}}=(value : String?)
            Grant::Encryption::Sealed.guard_plaintext!({{attr_name}}, value)
            previous_def(value)
          end

          def to_json(json : ::JSON::Builder) : Nil
            __unseal_lazy_attributes
            super
          end

          def to_yaml(yaml : ::YAML::Nodes::Builder) : Nil
            __unseal_lazy_attributes
            super
          end

          def read_attribute(name : String) : Grant::Columns::Type
            self.class.encrypted_query_attribute(name).try(&.unseal(self))
            super
          end
        {% end %}

        {% if ignore_case %}
          # The original case comes from the companion column; the column of
          # this name only holds the lower-cased value the lookups match.
          def {{attr}} : String?
            {% if lazy_on %}
              original_{{attr}} || __unseal_{{attr}}
            {% else %}
              @original_{{attr}} || @{{attr}}
            {% end %}
          end

          def {{attr}}=(value : String?)
            previous_def(value)
            self.original_{{attr}} = value
          end
        {% end %}

        def self.where_{{attr}}(value : {{base}})
          where({ {{attr_name}} => value })
        end

        def self.find_by_{{attr}}(value : {{base}})
          where_{{attr}}(value).first
        end
      {% else %}
        # Register callback on first encryption (only once per class)
        {% unless @type.has_constant?("ENCRYPTION_CALLBACK_REGISTERED") %}
          ENCRYPTION_CALLBACK_REGISTERED = true
          after_save :clear_encryption_cache
        {% end %}

        # Create the encrypted column (stores Base64-encoded string)
        column {{attr}}_encrypted : String?

        # Create virtual getter with caching
        def {{attr}} : String?
          # Check cache first
          if encrypted_attribute_cache.has_key?({{attr_name}})
            return encrypted_attribute_cache[{{attr_name}}]
          end

          encrypted = @{{attr}}_encrypted
          return nil if encrypted.nil?

          # Decrypt and cache
          decrypted = self.class.{{attr}}_encrypted_attribute.open(encrypted)
          encrypted_attribute_cache[{{attr_name}}] = decrypted
          decrypted
        end

        # Create virtual setter
        def {{attr}}=(value : String?)
          {% if downcase %}
            value = value.try(&.downcase)
          {% end %}
          # Update cache
          encrypted_attribute_cache[{{attr_name}}] = value

          if value.nil?
            @{{attr}}_encrypted = nil
          else
            @{{attr}}_encrypted = self.class.{{attr}}_encrypted_attribute.seal(value)
          end

          # Mark as changed for dirty tracking
          # Track the change in dirty tracking
          if responds_to?(:changed_attributes)
            ensure_dirty_tracking_initialized
            # Track encrypted column change
            old_val = dirty_tracking_hashes[0]["{{attr}}_encrypted"]? || nil
            dirty_tracking_hashes[1]["{{attr}}_encrypted"] = {old_val, @{{attr}}_encrypted}
          end
        end

        Grant::Columns::VirtualAttributeRegistry.register(
          {{@type.name.stringify}},
          {{attr_name}},
          ->(record : Grant::Base, value : Grant::Columns::Type) do
            record.as({{@type}}).{{attr}} = Grant::Columns::VirtualAttributeRegistry.string_value(value)
          end
        )

        # Add query support for deterministic fields
        {% if deterministic %}
          # Class method for querying encrypted attributes
          def self.where_{{attr}}(value : String)
            where({{attr}}_encrypted: {{attr}}_encrypted_attribute.query_value(value))
          end

          # Also support find_by for deterministic fields
          def self.find_by_{{attr}}(value : String)
            where_{{attr}}(value).first
          end
        {% end %}

        # Add attribute to the list of attributes for serialization exclusion
        {% if @type.has_method?(:json_options) %}
          json_options(except: [{{attr}}_encrypted])
        {% end %}
      {% end %}
    end
  end
end
