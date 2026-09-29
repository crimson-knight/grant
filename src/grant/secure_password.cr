require "crypto/bcrypt/password"
require "crypto/subtle"
require "./token_for"

module Grant
  # Bcrypt-backed secure passwords, in the style of ActiveModel's
  # `has_secure_password`.
  #
  # This file is an optional require (`require "grant/secure_password"`); the
  # core does not load it. Hashing uses the standard library's
  # `Crypto::Bcrypt::Password`, which compares in constant time.
  #
  # ```
  # require "grant/secure_password"
  #
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String?
  #   has_secure_password # stores a bcrypt hash in `password_digest`
  # end
  #
  # user = User.new(email: "a@example.com")
  # user.password = "s3cret"
  # user.password_confirmation = "s3cret"
  # user.save
  # user.authenticate("wrong")  # => nil
  # user.authenticate("s3cret") # => user
  # token = user.password_reset_token
  # User.find_by_password_reset_token(token) # => user (until the password changes)
  # ```
  #
  # Bcrypt is deliberately CPU-heavy and hashing happens in `password=`. Assign
  # passwords and call `authenticate` before opening a transaction or checking
  # out a connection; neither method touches the database.
  module SecurePassword
    # Bcrypt only uses the first 72 bytes of a password (the stdlib rejects
    # longer ones), so the validations cap the password at this many bytes.
    MAX_PASSWORD_BYTES = 72

    DEFAULT_COST = 12

    @@cost : Int32 = DEFAULT_COST

    # The bcrypt work factor used by `password=`. Set it once at boot; lower it
    # only in test environments.
    def self.cost : Int32
      @@cost
    end

    def self.cost=(value : Int32) : Int32
      raise ArgumentError.new("bcrypt cost must be within #{Crypto::Bcrypt::COST_RANGE}") unless Crypto::Bcrypt::COST_RANGE.includes?(value)
      @@cost = value
    end

    # Hashes *plain_text* with the configured cost. Raises `ArgumentError` when
    # it is empty or longer than 72 bytes.
    def self.digest(plain_text : String) : String
      Crypto::Bcrypt.new(key_bytes(plain_text), Random::Secure.random_bytes(Crypto::Bcrypt::SALT_SIZE), cost).to_s
    end

    # True when *plain_text* matches the bcrypt *digest* (constant-time). A
    # malformed digest or an out-of-range password never matches.
    def self.matches?(digest : String?, plain_text : String) : Bool
      return false if digest.nil? || digest.empty?
      return false unless (1..MAX_PASSWORD_BYTES).includes?(plain_text.bytesize)
      stored = Crypto::Bcrypt::Password.new(digest)
      salt_bytes = Crypto::Bcrypt::Base64.decode(stored.salt, Crypto::Bcrypt::SALT_SIZE)
      computed = Crypto::Bcrypt.new(key_bytes(plain_text), salt_bytes, stored.cost).digest
      encoded = Crypto::Bcrypt::Base64.encode(computed, computed.size - 1)
      Crypto::Subtle.constant_time_compare(stored.digest, encoded)
    rescue Crypto::Bcrypt::Error
      false
    end

    # Bcrypt keys are the password plus a NUL terminator, cut at 72 bytes. The
    # stdlib's string helpers count the terminator against the 72-byte limit
    # (so they reject a 72-byte password); building the key here allows the
    # full 72 bytes and stays compatible with standard bcrypt hashes.
    private def self.key_bytes(plain_text : String) : Bytes
      unless (1..MAX_PASSWORD_BYTES).includes?(plain_text.bytesize)
        raise ArgumentError.new("password must be 1 to #{MAX_PASSWORD_BYTES} bytes")
      end
      size = Math.min(plain_text.bytesize + 1, MAX_PASSWORD_BYTES)
      key = Bytes.new(size)
      key.copy_from(plain_text.to_unsafe, Math.min(plain_text.bytesize, size))
      key
    end

    # The salt portion of a bcrypt *digest* (its first 29 characters), or an
    # empty string. It changes whenever the password does.
    def self.salt(digest : String?) : String
      digest ? digest[0, 29] : ""
    end
  end

  abstract class Base
    # Declares a secure password. *attribute* (default `:password`) names the
    # virtual attribute; the hash is stored in `<attribute>_digest`, a
    # `String?` column this macro declares.
    #
    # Generates:
    #
    # * `#password=` (hashes immediately; `nil` clears the digest, an empty
    #   string is ignored), `#password`, `#password_confirmation`,
    #   `#password_challenge`;
    # * `#authenticate_password(plain)` and, for `:password`, `#authenticate(plain)`,
    #   both returning `self` or `nil`;
    # * with *validations* (default `true`): the digest must be present, the
    #   password at most 72 bytes, the confirmation (when assigned) must match,
    #   and a `password_challenge` (when assigned) must match the digest before
    #   the change;
    # * with *reset_token* (default `true`): `#password_reset_token` and
    #   `.find_by_password_reset_token(!)`, valid for *reset_token_expires_in*
    #   (default 15 minutes) and invalid once the password changes. These use
    #   `Grant::TokenFor`, so a signing secret must be configured.
    macro has_secure_password(attribute = :password, validations = true, reset_token = true, reset_token_expires_in = 15.minutes)
      {% attr = attribute.id %}

      column {{ attr }}_digest : String?

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ attr }} : String?

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ attr }}_confirmation : String?

      @[JSON::Field(ignore: true)]
      @[YAML::Field(ignore: true)]
      @{{ attr }}_challenge : String?

      # The plain-text password last assigned in memory; never persisted.
      def {{ attr }} : String?
        @{{ attr }}
      end

      # Hashes *plain_text* into `{{ attr }}_digest`. `nil` clears the digest;
      # an empty string is ignored. A value over 72 bytes is kept in memory so
      # validation can reject it, but is not hashed.
      def {{ attr }}=(plain_text : String?) : String?
        if plain_text.nil?
          @{{ attr }} = nil
          self.{{ attr }}_digest = nil
        elsif !plain_text.empty?
          @{{ attr }} = plain_text
          if plain_text.bytesize <= Grant::SecurePassword::MAX_PASSWORD_BYTES
            self.{{ attr }}_digest = Grant::SecurePassword.digest(plain_text)
          end
        end
        plain_text
      end

      def {{ attr }}_confirmation : String?
        @{{ attr }}_confirmation
      end

      def {{ attr }}_confirmation=(value : String?) : String?
        @{{ attr }}_confirmation = value
      end

      # When set, must match the digest as it was before this change (used to
      # confirm the current password before updating it).
      def {{ attr }}_challenge : String?
        @{{ attr }}_challenge
      end

      def {{ attr }}_challenge=(value : String?) : String?
        @{{ attr }}_challenge = value
      end

      {% for suffix in ["", "_confirmation", "_challenge"] %}
        Grant::Columns::VirtualAttributeRegistry.register(
          {{ @type.name.stringify }},
          "{{ attr }}{{ suffix.id }}",
          ->(record : Grant::Base, value : Grant::Columns::Type) do
            record.as({{ @type }}).{{ attr }}{{ suffix.id }} = Grant::Columns::VirtualAttributeRegistry.string_value(value)
          end
        )
      {% end %}

      # Returns `self` when *plain_text* matches the stored digest, else `nil`.
      def authenticate_{{ attr }}(plain_text : String) : self?
        Grant::SecurePassword.matches?(self.{{ attr }}_digest, plain_text) ? self : nil
      end

      {% if attr.stringify == "password" %}
        # Alias of `#authenticate_password`.
        def authenticate(plain_text : String) : self?
          authenticate_password(plain_text)
        end
      {% end %}

      # The bcrypt salt of the stored digest; changes with the password.
      def {{ attr }}_salt : String
        Grant::SecurePassword.salt(self.{{ attr }}_digest)
      end

      {% if validations %}
        validate :__{{ attr }}_digest_present
        validate :__{{ attr }}_length
        validate :__{{ attr }}_confirmation_matches
        validate :__{{ attr }}_challenge_matches

        private def __{{ attr }}_digest_present
          digest = self.{{ attr }}_digest
          plain = @{{ attr }}
          # An over-long password is reported by the length rule instead.
          return if plain && plain.bytesize > Grant::SecurePassword::MAX_PASSWORD_BYTES
          errors.add(:{{ attr }}, "can't be blank", :blank) if digest.nil? || digest.empty?
        end

        private def __{{ attr }}_length
          plain = @{{ attr }}
          if plain && plain.bytesize > Grant::SecurePassword::MAX_PASSWORD_BYTES
            errors.add(:{{ attr }}, "is too long (maximum is #{Grant::SecurePassword::MAX_PASSWORD_BYTES} bytes)", :too_long)
          end
        end

        private def __{{ attr }}_confirmation_matches
          confirmation = @{{ attr }}_confirmation
          return if confirmation.nil?
          errors.add(:{{ attr }}_confirmation, "doesn't match {{ attr.stringify.capitalize.id }}", :confirmation) unless @{{ attr }} == confirmation
        end

        private def __{{ attr }}_challenge_matches
          challenge = @{{ attr }}_challenge
          return if challenge.nil?
          unless Grant::SecurePassword.matches?({{ attr }}_digest_was, challenge)
            errors.add(:{{ attr }}_challenge, "is invalid", :invalid)
          end
        end
      {% end %}

      {% if reset_token %}
        include Grant::TokenFor

        generates_token_for :{{ attr }}_reset, expires_in: {{ reset_token_expires_in }} do
          {{ attr }}_salt
        end

        # A signed token that expires and stops working once the password changes.
        def {{ attr }}_reset_token : String
          generate_token_for(:{{ attr }}_reset)
        end

        def self.find_by_{{ attr }}_reset_token(token : String) : self?
          find_by_token_for(:{{ attr }}_reset, token)
        end

        def self.find_by_{{ attr }}_reset_token!(token : String) : self
          find_by_token_for!(:{{ attr }}_reset, token)
        end
      {% end %}
    end
  end
end
