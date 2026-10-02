module Grant::Encryption
  # Keeps each model's encrypted attribute definitions isolated. Inherited
  # class variables made one model's declarations visible to every other model.
  module EncryptedAttributeRegistry
    @@attributes = {} of String => Hash(String, EncryptedAttribute)
    @@mutex = Mutex.new

    def self.for(model_name : String) : Hash(String, EncryptedAttribute)
      @@mutex.synchronize do
        @@attributes[model_name]?.try(&.dup) || ({} of String => EncryptedAttribute)
      end
    end

    # One attribute without copying the registry. Registration happens while
    # classes are defined, so reads do not take the lock.
    def self.lookup(model_name : String, attribute_name : String) : EncryptedAttribute?
      @@attributes[model_name]?.try(&.[attribute_name]?)
    end

    def self.register(model_name : String, attribute_name : String, attribute : EncryptedAttribute) : Nil
      @@mutex.synchronize do
        @@attributes[model_name] ||= {} of String => EncryptedAttribute
        @@attributes[model_name][attribute_name] = attribute
      end
    end
  end

  # Handles the encryption/decryption lifecycle for individual attributes
  class EncryptedAttribute
    alias Writer = Proc(Grant::Base, String?, Nil)
    alias Reader = Proc(Grant::Base, String?)

    # What `encrypts` was declared with, beyond the attribute name and
    # `deterministic:`.
    struct Options
      getter? downcase : Bool
      getter? ignore_case : Bool
      getter? compress : Bool
      getter compress_threshold : Int32?
      getter? support_unencrypted_data : Bool?
      getter previous : Array(Scheme)
      # True when the value lives in a column of the attribute's own name
      # (`encrypts email : String`) rather than in `<attr>_encrypted`.
      getter? transparent : Bool
      getter type_name : String

      def initialize(
        @downcase : Bool = false,
        @ignore_case : Bool = false,
        @compress : Bool = false,
        @compress_threshold : Int32? = nil,
        @support_unencrypted_data : Bool? = nil,
        @previous : Array(Scheme) = [] of Scheme,
        @transparent : Bool = false,
        @type_name : String = "String",
      )
      end
    end

    getter model_class : Grant::Base.class
    getter attribute_name : String
    getter deterministic : Bool
    getter column_name : String
    getter options : Options

    # Decrypted value cache
    @decrypted_cache = {} of UInt64 => String?

    # Keys of the older schemes, rebuilt when `KeyProvider.generation` moves.
    @previous_key_sets = [] of KeyProvider::KeySet
    @key_sets_generation = -1
    @key_memo = {} of Tuple(UInt64, Bool) => Bytes?
    @key_mutex = Mutex.new

    def initialize(
      @model_class : Grant::Base.class,
      @attribute_name : String,
      @deterministic : Bool,
      @writer : Writer,
      column_name : String? = nil,
      @options : Options = Options.new,
      @plain_reader : Reader? = nil,
      @stored_reader : Reader? = nil,
      @unsealer : Proc(Grant::Base, Nil)? = nil,
    )
      @column_name = column_name || "#{attribute_name}_encrypted"
    end

    # Assigns plaintext through the model's generated encrypted setter.
    def assign(record : Grant::Base, value : String?) : Nil
      @writer.call(record, value)
    end

    # Whether the value is stored in a column named like the attribute.
    def transparent? : Bool
      @options.transparent?
    end

    # Whether the attribute is decrypted when first read rather than when its
    # row loads (see `Grant::Encryption::Sealed`).
    def lazy? : Bool
      !@unsealer.nil?
    end

    # Decrypts *record*'s value for this attribute if it is still sealed. A
    # no-op for an eager attribute or one that was already read.
    def unseal(record : Grant::Base) : Nil
      @unsealer.try(&.call(record))
    end

    # The attribute's current value as the text that gets encrypted, or `nil`.
    def plaintext_for(record : Grant::Base) : String?
      @plain_reader.try(&.call(record))
    end

    # The value as the database holds (or would hold) it.
    def ciphertext_for(record : Grant::Base) : String?
      return @stored_reader.try(&.call(record)) unless transparent?
      plaintext_for(record).try { |plain| seal(plain) }
    end

    # Whether unencrypted stored values are read as they are, rather than
    # failing to decrypt: the attribute's own `support_unencrypted_data:` when
    # given, else `Config.support_unencrypted_data`.
    def support_unencrypted_data? : Bool
      explicit = @options.support_unencrypted_data?
      explicit.nil? ? Config.support_unencrypted_data : explicit
    end

    # Encrypts *plain* and returns the Base64 text that is stored. Applies
    # `downcase:`/`ignore_case:` and `compress:`. Returns *plain* untouched
    # inside `Grant::Encryption.without_encryption`.
    def seal(plain : String) : String
      return plain if Encryption.current_context.encryption_disabled?

      text = @options.downcase? || @options.ignore_case? ? plain.downcase : plain
      threshold = @options.compress_threshold || Config.compress_threshold
      text = Compression.encode(text, @options.compress?, threshold)

      encrypted = Cipher.encrypt(text, write_key, @deterministic)
      log_operation("encrypt", plain.size, encrypted.size) if Config.verbose_logging
      Base64.strict_encode(encrypted)
    end

    # Decrypts stored *stored* text and returns the plaintext. Tries the
    # current keys first, then older keys and `previous:` schemes newest
    # first. Returns *stored* unchanged inside `without_encryption`, and, with
    # `support_unencrypted_data`, when it is not an encrypted payload (decided
    # from the payload's version byte, without raising).
    def open(stored : String) : String
      return stored if Encryption.current_context.encryption_disabled?
      open_with_index(stored)[0]
    end

    # `open` plus which scheme worked: 0 for the current keys, 1 and up for
    # older ones in the order tried, -1 when the value was read as plaintext.
    def open_with_index(stored : String) : Tuple(String, Int32)
      return {"", 0} if stored.empty?

      bytes = begin
        Base64.decode(stored)
      rescue ex : Base64::Error
        return {stored, -1} if support_unencrypted_data?
        raise Cipher::DecryptionError.new("Failed to decode Base64: #{ex.message}")
      end

      if !Cipher.encrypted_payload?(bytes)
        return {stored, -1} if support_unencrypted_data?
      end

      hint = Cipher.deterministic_payload?(bytes)
      attempted = false
      index = 0

      if pinned = Encryption.current_context.key_set
        opened, tried = try_key_set(bytes, hint, pinned, nil)
        return {Compression.decode(opened), 0} if opened
        attempted = tried
      else
        opened, tried = try_current_keys(bytes, hint)
        return {Compression.decode(opened), 0} if opened
        attempted = tried
        previous_key_sets.each do |key_set|
          index += 1
          opened, tried = try_key_set(bytes, hint, key_set, index)
          return {Compression.decode(opened), index} if opened
          attempted ||= tried
        end
      end

      unless attempted
        raise KeyProvider::KeyError.new("Primary encryption key not configured. Set Grant::Encryption::KeyProvider.primary_key")
      end
      raise Cipher::DecryptionError.new("HMAC verification failed - data may have been tampered with")
    end

    # The ciphertext to compare a stored deterministic value with: one
    # encryption per call, whatever the number of rows.
    def query_value(plain : String) : String
      raise ArgumentError.new("Cannot query non-deterministic encrypted field: #{attribute_name}") unless @deterministic
      seal(plain)
    end

    # The values a lookup should match: the ciphertext and, while
    # `support_unencrypted_data` is on, the plaintext rows that predate
    # encryption.
    def query_values(plain : String) : Array(String)
      sealed = query_value(plain)
      return [sealed] unless support_unencrypted_data?
      text = @options.downcase? || @options.ignore_case? ? plain.downcase : plain
      sealed == text ? [sealed] : [sealed, text]
    end

    # Encrypt a value
    def encrypt(value : String?) : Bytes?
      return if value.nil?

      key = derive_key
      encrypted = Cipher.encrypt(value, key, deterministic)

      log_operation("encrypt", value.size, encrypted.size) if Config.verbose_logging

      encrypted
    end

    # Decrypt a value
    def decrypt(encrypted : Bytes?, instance_id : UInt64? = nil) : String?
      return if encrypted.nil? || encrypted.empty?

      # Check cache if instance_id provided
      if instance_id && @decrypted_cache.has_key?(instance_id)
        return @decrypted_cache[instance_id]
      end

      if support_unencrypted_data? && !Cipher.encrypted_payload?(encrypted)
        plaintext = String.new(encrypted)
        log_operation("decrypt_unencrypted", encrypted.size, plaintext.size) if Config.verbose_logging
        return plaintext
      end

      key = derive_key
      decrypted = Cipher.decrypt(encrypted, key)

      # Cache if instance_id provided
      @decrypted_cache[instance_id] = decrypted if instance_id

      log_operation("decrypt", encrypted.size, decrypted.size) if Config.verbose_logging

      decrypted
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

    # The key new writes use: the fiber's pinned key when there is one,
    # otherwise the process-wide key.
    private def write_key : Bytes
      derive_key
    end

    # Derive the encryption key for this attribute
    private def derive_key : Bytes
      if pinned = Encryption.current_context.key_set
        return KeyProvider.derive_key_from_set?(model_class.name, attribute_name, deterministic, pinned) ||
          raise KeyProvider::KeyError.new(deterministic ? "Deterministic encryption key not pinned in this context" : "Primary encryption key not pinned in this context")
      end
      KeyProvider.derive_key(model_class.name, attribute_name, deterministic)
    end

    # Tries the process-wide current keys. The second value says whether any
    # key was available to try.
    private def try_current_keys(bytes : Bytes, deterministic_first : Bool) : Tuple(String?, Bool)
      attempted = false
      2.times do |round|
        deterministic_key = deterministic_first ? round == 0 : round == 1
        configured = deterministic_key ? KeyProvider.deterministic_key : KeyProvider.primary_key
        next unless configured
        attempted = true
        key = KeyProvider.derive_key(model_class.name, attribute_name, deterministic_key)
        if opened = Cipher.decrypt?(bytes, key)
          log_operation("decrypt", bytes.size, opened.size) if Config.verbose_logging
          return {opened, true}
        end
      end
      {nil, attempted}
    end

    # Tries one older key pair; *memo_id* is nil for a fiber-pinned pair,
    # which is derived every time instead of remembered.
    private def try_key_set(bytes : Bytes, deterministic_first : Bool, key_set : KeyProvider::KeySet, memo_id : Int32?) : Tuple(String?, Bool)
      attempted = false
      2.times do |round|
        deterministic_key = deterministic_first ? round == 0 : round == 1
        key = memo_id ? memoized_key(key_set, deterministic_key) : KeyProvider.derive_key_from_set?(model_class.name, attribute_name, deterministic_key, key_set)
        next unless key
        attempted = true
        if opened = Cipher.decrypt?(bytes, key)
          log_operation("decrypt", bytes.size, opened.size) if Config.verbose_logging
          return {opened, true}
        end
      end
      {nil, attempted}
    end

    private def memoized_key(key_set : KeyProvider::KeySet, deterministic_key : Bool) : Bytes?
      @key_mutex.synchronize do
        memo_key = {key_set.object_id, deterministic_key}
        return @key_memo[memo_key] if @key_memo.has_key?(memo_key)
        @key_memo[memo_key] = KeyProvider.derive_key_from_set?(model_class.name, attribute_name, deterministic_key, key_set)
      end
    end

    # Older key pairs, newest first: the `Config.primary_keys` history, then
    # this attribute's `previous:` schemes.
    private def previous_key_sets : Array(KeyProvider::KeySet)
      generation = KeyProvider.generation
      @key_mutex.synchronize do
        if @key_sets_generation != generation
          salt = KeyProvider.key_derivation_salt
          sets = KeyProvider.previous_key_sets.dup
          @options.previous.each do |scheme|
            next unless scheme.overrides_keys?
            sets << KeyProvider::KeySet.new(scheme.primary_key, scheme.deterministic_key, scheme.salt || salt)
          end
          @previous_key_sets = sets
          @key_memo.clear
          @key_sets_generation = generation
        end
        @previous_key_sets
      end
    end

    # Log encryption operations
    private def log_operation(operation : String, input_size : Int32, output_size : Int32)
      Grant::Encryption::Log.debug do
        "#{operation} #{model_class.name}.#{attribute_name}: #{input_size} bytes -> #{output_size} bytes"
      end
    end
  end

  # Logger for encryption operations
  Log = ::Log.for("grant.encryption")
end
