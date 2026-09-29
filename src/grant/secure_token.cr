require "random/secure"
require "base64"

module Grant
  # Cryptographically random tokens for model attributes, in the style of Rails'
  # `has_secure_token`.
  #
  # `has_secure_token :auth_token` adds a `String?` column that is auto-populated
  # with a random token on create (if not already set), plus a method to rotate
  # it. Tokens are drawn from `Random::Secure`, so they are suitable for password-
  # reset links, API keys, invitation codes, etc.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   has_secure_token :auth_token # 24-char base58 by default
  #   has_secure_token :api_key, length: 32, alphabet: :hex
  # end
  #
  # u = User.create
  # u.auth_token            # => e.g. "rX9kLm2pQvNbT7wYzA4cDeF8" (set on create)
  # u.regenerate_auth_token # rotates to a fresh token and saves it
  # ```
  module SecureToken
    # Declares *name* as an auto-generated secure-token column.
    #
    # For `has_secure_token :auth_token` this generates:
    #
    # * a `auth_token : String?` column;
    # * a `before_create` hook that fills the column with a fresh token **only if
    #   it is still `nil`** (an explicitly assigned value is preserved);
    # * `#regenerate_auth_token` / `#regenerate_auth_token!` — assign a new
    #   random token and persist it (the bang form raises on failure);
    # * `#assign_new_auth_token` — assigns a new token in memory only.
    #
    # *on* picks when the token is first generated: `:create` (default, in a
    # `before_create` hook) or `:initialize` (as soon as `Model.new` builds a
    # new record, so the token is readable before saving).
    #
    # *length* is the token length in characters (default `24`). *alphabet*
    # selects the character set: `:base58` (default, Bitcoin-style, omits
    # look-alike `0 O I l`), `:hex`, or `:base64` (URL-safe, unpadded).
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   has_secure_token :auth_token
    # end
    #
    # u = User.create # auth_token auto-filled
    # old = u.auth_token
    # u.regenerate_auth_token # persists
    # u.auth_token == old     # => false
    # ```
    macro has_secure_token(name, length = 24, alphabet = :base58, on = :create)
      column {{ name.id }} : String?

      # Assigns a freshly generated secure token to `{{ name.id }}` in memory
      # only; nothing is written to the database. Returns the new token.
      def assign_new_{{ name.id }} : String
        token = Grant::SecureToken.generate_secure_token(
          length: {{ length }},
          alphabet: {{ alphabet }}
        )
        self.{{ name.id }} = token
        token
      end

      # Rotates `{{ name.id }}` and persists it (validations skipped, callbacks
      # run), like ActiveRecord's `regenerate_<name>`. Returns `false` when the
      # save fails.
      def regenerate_{{ name.id }} : Bool
        assign_new_{{ name.id }}
        save(validate: false)
      end

      # Like `regenerate_{{ name.id }}` but raises `Grant::RecordNotSaved` when the
      # save fails.
      def regenerate_{{ name.id }}! : Bool
        assign_new_{{ name.id }}
        save(validate: false) || raise save_failure_error
      end

      {% if on == :initialize %}
        after_initialize :generate_{{ name.id }}_on_initialize

        private def generate_{{ name.id }}_on_initialize
          assign_new_{{ name.id }} if new_record? && self.{{ name.id }}.nil?
        end
      {% elsif on == :create %}
        before_create :generate_{{ name.id }}_if_needed
      {% else %}
        {% raise "has_secure_token on: must be :create or :initialize, got #{on}" %}
      {% end %}

      private def generate_{{ name.id }}_if_needed
        assign_new_{{ name.id }} if self.{{ name.id }}.nil?
      end
    end

    # Generates a cryptographically random token of *length* characters using
    # `Random::Secure`.
    #
    # *alphabet* selects the character set: `:base58` (default; omits the
    # look-alike characters `0`, `O`, `I`, `l`), `:hex`, or `:base64` (URL-safe,
    # unpadded, truncated to *length*). Raises for any other symbol. This is the
    # standalone generator the `has_secure_token` macro uses; call it directly when
    # you need a token outside a model.
    #
    # ```
    # Grant::SecureToken.generate_secure_token                             # => 24-char base58
    # Grant::SecureToken.generate_secure_token(length: 16)                 # => 16-char base58
    # Grant::SecureToken.generate_secure_token(length: 32, alphabet: :hex) # => 32 hex chars
    # ```
    def self.generate_secure_token(length : Int32 = 24, alphabet : Symbol = :base58) : String
      case alphabet
      when :base58
        generate_base58_token(length)
      when :hex
        generate_hex_token(length)
      when :base64
        generate_base64_token(length)
      else
        raise "Unsupported alphabet: #{alphabet}"
      end
    end

    private def self.generate_base58_token(length : Int32) : String
      # Base58 alphabet (Bitcoin-style, no 0, O, I, l)
      alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

      String.build(length) do |str|
        length.times do
          str << alphabet[Random::Secure.rand(alphabet.size)]
        end
      end
    end

    private def self.generate_hex_token(length : Int32) : String
      Random::Secure.hex(length // 2)
    end

    private def self.generate_base64_token(length : Int32) : String
      # Generate enough bytes to get the desired length after encoding
      bytes_needed = (length * 3.0 / 4.0).ceil.to_i
      Base64.urlsafe_encode(Random::Secure.random_bytes(bytes_needed), padding: false)[0...length]
    end
  end
end
