require "json"
require "base64"
require "openssl/hmac"
require "crypto/subtle"

# Tamper-proof, optionally expiring signed IDs for a model record, in the style
# of Rails' `signed_id`.
#
# A signed ID encodes a record's primary key together with a *purpose* and an
# optional expiry, all protected by an HMAC-SHA256 signature. It is safe to put in
# a URL or email (e.g. a password-reset or email-confirmation link): the recipient
# cannot forge or alter it, and `find_signed` only returns the record when the
# signature, purpose, and (if set) expiry all check out.
#
# Every `Grant::Base` model has these methods, as in ActiveRecord; no `include`
# is needed (`include Grant::SignedId` is still accepted). The methods are plain
# definitions, so a model that never calls them pays nothing. Models keyed by a
# composite primary key (or `query_constraints`) sign the whole key tuple. The
# signing secret comes from `Grant::TokenFor.configure` (or
# `Grant::SignedId.configure`), falling back to the `GRANT_SIGNING_SECRET`
# environment variable; generating or verifying a token without either raises
# `Grant::MissingSigningSecret`.
#
# ```
# ENV["GRANT_SIGNING_SECRET"] = "a-long-random-secret"
#
# class User < Grant::Base
#   column id : Int64, primary: true
# end
#
# user = User.create
# token = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)
#
# # later, from the link:
# User.find_signed(token, purpose: :password_reset)      # => the user
# User.find_signed(token, purpose: :email_confirmation)  # => nil (wrong purpose)
# User.find_signed!(token, purpose: :email_confirmation) # raises Grant::InvalidSignedId
# ```
module Grant
  # Raised by `find_signed!` and `find_by_token_for!` when the signature, purpose,
  # or expiry of a token does not check out.
  class InvalidSignedId < ErrorBase
    def initialize(message : String = "Invalid or expired signed id", cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # Raised by `find_by_token_for!` when a token is malformed, forged, expired,
  # for another purpose, or invalidated by a change to the record's data.
  class InvalidToken < ErrorBase
    def initialize(message : String = "Invalid or expired token", cause : ::Exception? = nil)
      super(message, cause)
    end
  end

  # Raised when a token is generated or verified with no signing secret
  # configured.
  class MissingSigningSecret < ErrorBase
    def initialize
      super("No signing secret: call Grant::TokenFor.configure or set GRANT_SIGNING_SECRET")
    end
  end

  # Signing keys shared by `Grant::SignedId` and `Grant::TokenFor`.
  #
  # Set the secret once at the app boundary. When it is left unset, the
  # `GRANT_SIGNING_SECRET` environment variable is read once, on first use. `previous_secrets` are accepted for verification only, so a key
  # can be rotated without invalidating tokens already handed out.
  class SigningConfig
    property secret : String?
    property previous_secrets : Array(String) = [] of String
  end

  # HMAC-SHA256 envelope signing behind `Grant::SignedId` and `Grant::TokenFor`.
  module Signer
    # The decoded, signature-checked contents of a token.
    struct Payload
      include JSON::Serializable

      getter id : String
      getter purpose : String
      getter data : String?
      getter expires_at : Int64?

      def expired?(now : Time = Time.utc) : Bool
        if at = expires_at
          at < now.to_unix
        else
          false
        end
      end
    end

    private struct Envelope
      include JSON::Serializable

      getter data : String
      getter signature : String
    end

    @@config = SigningConfig.new

    def self.config : SigningConfig
      @@config
    end

    # Signs *json* for *context* with the primary secret. The context (token kind and
    # model table) is part of the MAC input, so a token minted for one model or
    # token kind never verifies for another, as ActiveRecord binds the model name
    # into the purpose.
    def self.sign(json : String, context : String) : String
      mac(primary_secret, json, context)
    end

    def self.envelope(json : String, context : String) : String
      wrapper = {
        "data"      => Base64.urlsafe_encode(json, padding: false),
        "signature" => sign(json, context),
      }
      Base64.urlsafe_encode(wrapper.to_json, padding: false)
    end

    # Returns the signed JSON body of *token*, or `nil` when it is malformed or
    # the signature matches no configured secret for *context*. Only decode and
    # parse errors are rescued.
    def self.open(token : String, context : String) : String?
      envelope = Envelope.from_json(String.new(Base64.decode(token)))
      json = String.new(Base64.decode(envelope.data))
      signature = envelope.signature
      verified = false
      each_secret do |secret|
        # Evaluate every candidate without short-circuiting on the first hit.
        verified = true if Crypto::Subtle.constant_time_compare(signature, mac(secret, json, context))
      end
      verified ? json : nil
    rescue Base64::Error | JSON::ParseException
      nil
    end

    def self.open_payload(token : String, context : String) : Payload?
      json = open(token, context)
      return nil unless json
      Payload.from_json(json)
    rescue JSON::ParseException
      nil
    end

    private def self.mac(secret : String, json : String, context : String) : String
      digest = OpenSSL::HMAC.digest(:sha256, secret, "#{context}\n#{json}")
      Base64.urlsafe_encode(digest, padding: false)
    end

    # The configured secret. The `GRANT_SIGNING_SECRET` fallback is read from the
    # environment once, on first use, and kept in the config; it is not re-read
    # per token.
    private def self.primary_secret : String
      if secret = config.secret
        return secret
      end
      config.secret = ENV["GRANT_SIGNING_SECRET"]? || raise MissingSigningSecret.new
    end

    private def self.each_secret(& : String ->)
      yield primary_secret
      config.previous_secrets.each { |secret| yield secret }
    end
  end
end

module Grant::SignedId
  macro included
    extend ClassMethods
  end

  # Configures the signing keys shared with `Grant::TokenFor`. Call it once at
  # the app boundary.
  def self.configure(& : Grant::SigningConfig ->) : Nil
    yield Grant::Signer.config
  end

  # Returns a signed, URL-safe token encoding this record's id, the given
  # *purpose*, and an optional expiry.
  #
  # *purpose* defaults to the model's table name. The token is bound to it, so a
  # token minted for `:password_reset` cannot be redeemed for
  # `:email_confirmation`. *expires_in* (relative) or *expires_at* (absolute)
  # bound the lifetime; with neither the token never expires. Passing both
  # raises `ArgumentError`.
  #
  # ```
  # user.signed_id                                               # purpose is "users"
  # user.signed_id(purpose: :password_reset)                     # never expires
  # user.signed_id(purpose: :password_reset, expires_in: 1.hour) # 1-hour window
  # user.signed_id(purpose: :invite, expires_at: Time.utc(2030, 1, 1))
  # ```
  def signed_id(purpose : Symbol | String | Nil = nil, expires_in : Time::Span? = nil, expires_at : Time? = nil) : String
    raise ArgumentError.new("Pass either expires_in or expires_at, not both") if expires_in && expires_at
    expiry = expires_at || (expires_in ? Time.utc + expires_in : nil)

    payload = {
      "id"         => signed_id_key,
      "purpose"    => (purpose || self.class.table_name).to_s,
      "expires_at" => expiry.try(&.to_unix),
    }

    self.class.generate_signed_token(payload)
  end

  # The record's key as it is signed: the primary key, or a JSON array of the
  # key columns' values for a composite key.
  private def signed_id_key : String
    columns = self.class.signed_id_key_columns
    if columns.size == 1
      read_attribute(columns.first).to_s
    else
      columns.map { |column_name| read_attribute(column_name).to_s }.to_json
    end
  end

  # Class-level entry points for `Grant::SignedId`, mixed in via `extend
  # ClassMethods` when a model does `include Grant::SignedId`.
  module ClassMethods
    # Finds and returns the record referenced by *signed_id*, or `nil` if the
    # token is invalid for *purpose* (default: the table name).
    #
    # Returns `nil` when the signature does not verify, the token is malformed,
    # the *purpose* does not match, the token has expired, or no record with the
    # encoded id exists. Only decode and verify failures become `nil`; a missing
    # signing secret still raises `Grant::MissingSigningSecret`.
    #
    # ```
    # User.find_signed(token, purpose: :password_reset)     # => the user
    # User.find_signed("garbage", purpose: :password_reset) # => nil
    # ```
    def find_signed(signed_id : String, purpose : Symbol | String | Nil = nil) : self?
      payload = signed_id_payload(signed_id, purpose)
      return nil unless payload
      find_by_signed_key(payload.id)
    end

    # Like `find_signed` but raises `Grant::InvalidSignedId` for a bad, forged,
    # expired, or wrong-purpose token and `Grant::RecordNotFound` when the record
    # is gone.
    def find_signed!(signed_id : String, purpose : Symbol | String | Nil = nil) : self
      payload = signed_id_payload(signed_id, purpose) || raise Grant::InvalidSignedId.new
      find_by_signed_key(payload.id) || raise Grant::RecordNotFound.new("Couldn't find #{name} with signed id")
    end

    # The columns that identify a record in a signed id: the primary key, or
    # the key tuple of a composite-key / `query_constraints` model.
    def signed_id_key_columns : Array(String)
      {% if @type.class.has_method?(:persistence_key_columns) %}
        persistence_key_columns
      {% else %}
        [primary_name]
      {% end %}
    end

    # Serializes *payload* to JSON, signs it with HMAC-SHA256, and returns the
    # Base64-url-encoded `{data, signature}` envelope. Low-level building block for
    # `#signed_id`; prefer that method.
    def generate_signed_token(payload : Hash(String, String | Int64 | Nil)) : String
      Grant::Signer.envelope(payload.to_json, signed_id_signing_context)
    end

    # Verifies a token produced by `generate_signed_token` and returns its decoded
    # payload as a `Hash(String, JSON::Any)`, or `nil` if the signature does not
    # verify or the token is malformed. Does not check purpose/expiry.
    def verify_signed_token(token : String) : Hash(String, JSON::Any)?
      json = Grant::Signer.open(token, signed_id_signing_context)
      return nil unless json
      JSON.parse(json).as_h?
    rescue JSON::ParseException
      nil
    end

    # Finds the record for a signed key (see `signed_id_key`). Key values are
    # strings in the payload; they are converted to the column types so
    # PostgreSQL and SQLite compare like types.
    private def find_by_signed_key(key : String) : self?
      columns = signed_id_key_columns
      if columns.size == 1
        # IDs are encoded as strings in the signed payload. Restore integer
        # bindings before querying so PostgreSQL and SQLite compare like types.
        return find(key.to_i64? || key)
      end

      parts = begin
        Array(String).from_json(key)
      rescue JSON::ParseException
        return nil
      end
      return nil unless parts.size == columns.size

      criteria = Grant::ModelArgs.new
      {% begin %}
        columns.each_with_index do |column_name, index|
          case column_name
          {% for ivar in @type.instance_vars.select(&.annotation(Grant::Column)) %}
            {% setter_type = ivar.annotation(Grant::Column)[:setter_type] %}
          when {{ ivar.name.stringify }}
            begin
              value = Grant::Type.convert_type(parts[index], {{ setter_type }})
            rescue ArgumentError
              return nil
            end
            return nil unless value.is_a?({{ setter_type }})
            criteria[column_name] = value
          {% end %}
          else
            return nil
          end
        end
      {% end %}
      where(criteria).first
    end

    private def signed_id_payload(token : String, purpose : Symbol | String | Nil) : Grant::Signer::Payload?
      payload = Grant::Signer.open_payload(token, signed_id_signing_context)
      return nil unless payload
      return nil unless payload.purpose == (purpose || table_name).to_s
      return nil if payload.expired?
      payload
    end

    private def signed_id_signing_context : String
      "signed_id/#{table_name}"
    end
  end
end

# Every model signs ids, as in ActiveRecord. Nothing here is generated per model.
abstract class Grant::Base
  include Grant::SignedId
end
