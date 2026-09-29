require "json"
require "base64"
require "openssl/hmac"
require "./signed_id"

# Data-invalidating, expiring tokens for a model record, in the style of Rails'
# `generates_token_for`.
#
# Like `Grant::SignedId`, a token-for encodes a record's id, a purpose, and an
# optional expiry under an HMAC-SHA256 signature. The difference is that it also
# captures a snapshot of some record-derived data (returned by a block) at mint
# time. When the token is redeemed, the block is re-evaluated against the current
# record and the token is rejected if the data has changed. This auto-invalidates
# a token when the underlying state moves on — e.g. a password-reset token that
# stops working the moment the password (or its salt) changes.
#
# This module is **opt-in** — `include Grant::TokenFor` in models that need it.
# Each purpose is declared with `generates_token_for`. The signing secret comes
# from `Grant::TokenFor.configure` (read once at the app boundary), falling back
# to `GRANT_SIGNING_SECRET`.
#
# ```
# Grant::TokenFor.configure { |c| c.secret = "a-long-random-secret" }
#
# class User < Grant::Base
#   include Grant::TokenFor
#   column id : Int64, primary: true
#   column email : String?
#   column password_salt : String?
#
#   # token invalidates when password_salt changes:
#   generates_token_for :password_reset, expires_in: 15.minutes do
#     password_salt
#   end
# end
#
# user = User.create(email: "a@b.com", password_salt: "salt1")
# token = user.generate_token_for(:password_reset)
#
# User.find_by_token_for(:password_reset, token) # => the user
#
# user.update(password_salt: "salt2")
# User.find_by_token_for(:password_reset, token) # => nil (data changed)
# ```
module Grant::TokenFor
  # Configures the signing keys shared with `Grant::SignedId`. Call it once at
  # the app boundary.
  #
  # ```
  # Grant::TokenFor.configure do |c|
  #   c.secret = ENV["APP_SECRET"]
  #   c.previous_secrets = [ENV["OLD_APP_SECRET"]] # verify-only, for rotation
  # end
  # ```
  def self.configure(& : Grant::SigningConfig ->) : Nil
    yield Grant::Signer.config
  end

  macro included
    extend ClassMethods

    class_getter token_for_definitions = {} of Symbol => TokenForDefinition

    # Internal record of one `generates_token_for` declaration: its expiry and the
    # proc that derives the invalidation data from a record.
    struct TokenForDefinition
      getter expires_in : Time::Span?
      getter block : Proc(Grant::Base, String)

      def initialize(@expires_in : Time::Span?, @block : Proc(Grant::Base, String))
      end
    end

    # Declares a token *purpose* and the record-derived data that invalidates it.
    #
    # The block is evaluated in the record's instance scope; whatever it returns
    # (stringified) is snapshotted into the token at mint time and compared again
    # at redemption. When the value differs, `find_by_token_for` returns `nil`.
    # *expires_in* additionally bounds the token's lifetime (`nil` = no expiry).
    #
    # A block is required. Generates no public method itself — it registers the
    # purpose so `#generate_token_for` and `.find_by_token_for` can use it.
    #
    # ```
    # class User < Grant::Base
    #   include Grant::TokenFor
    #   column id : Int64, primary: true
    #   column password_salt : String?
    #
    #   generates_token_for :password_reset, expires_in: 15.minutes do
    #     password_salt # token dies when the salt changes
    #   end
    # end
    # ```
    macro generates_token_for(purpose, expires_in = nil, &block)
      \{% if block %}
        self.token_for_definitions[\{{ purpose }}] = TokenForDefinition.new(
          expires_in: \{{ expires_in }},
          block: ->(record : Grant::Base) do
            instance = record.as(self)
            instance.\{{ block.body }}.to_s
          end
        )
      \{% else %}
        raise "generates_token_for requires a block"
      \{% end %}
    end
  end

  # Mints a token for *purpose*, embedding this record's id, the current value of
  # the purpose's data block, and the configured expiry.
  #
  # Raises if *purpose* was never declared with `generates_token_for`. The
  # returned token is URL/email-safe. Redeem it later with
  # `.find_by_token_for(purpose, token)`. Requires `GRANT_SIGNING_SECRET`.
  #
  # ```
  # ENV["GRANT_SIGNING_SECRET"] = "secret"
  # token = user.generate_token_for(:password_reset)
  # ```
  def generate_token_for(purpose : Symbol) : String
    definition = self.class.token_for_definitions[purpose]?
    raise "No token_for definition for purpose: #{purpose}" unless definition

    # Generate data for token uniqueness
    unique_data = definition.block.call(self)

    payload = {
      "id"         => self.id.to_s,
      "purpose"    => purpose.to_s,
      "data"       => unique_data,
      "expires_at" => (exp = definition.expires_in) ? (Time.utc + exp).to_unix : nil,
    }

    self.class.generate_token_for_payload(payload)
  end

  # Class-level entry points for `Grant::TokenFor`, mixed in via `extend
  # ClassMethods` when a model does `include Grant::TokenFor`.
  module ClassMethods
    # Finds and returns the record for *token* under *purpose*, or `nil` if the
    # token is invalid.
    #
    # Returns `nil` (never raises) when the signature fails, the purpose does not
    # match, the token has expired, the record no longer exists, or — crucially —
    # the purpose's data block now returns a different value than when the token
    # was minted. Requires `GRANT_SIGNING_SECRET`.
    #
    # ```
    # ENV["GRANT_SIGNING_SECRET"] = "secret"
    # token = user.generate_token_for(:password_reset)
    # User.find_by_token_for(:password_reset, token) # => the user (until salt changes)
    # ```
    def find_by_token_for(purpose : Symbol, token : String) : self?
      record_for_token(purpose, token)
    end

    # Like `find_by_token_for` but raises `Grant::InvalidToken` when the token is
    # malformed, forged, expired, for another purpose, or invalidated by a change
    # to the record's data, and `Grant::RecordNotFound` when the record is gone.
    #
    # ```
    # User.find_by_token_for!(:password_reset, token) # => the user, or raises
    # ```
    def find_by_token_for!(purpose : Symbol, token : String) : self
      payload = token_for_payload(purpose, token) || raise Grant::InvalidToken.new
      record = find_token_record(payload) || raise Grant::RecordNotFound.new("Couldn't find #{name} for token")
      token_data_current?(purpose, record, payload) ? record : raise Grant::InvalidToken.new
    end

    # Serializes *payload* to JSON, signs it with HMAC-SHA256, and returns the
    # Base64-url-encoded envelope. Low-level building block for
    # `#generate_token_for`; prefer that.
    def generate_token_for_payload(payload : Hash(String, String | Int64 | Nil)) : String
      Grant::Signer.envelope(payload.to_json, token_for_signing_context)
    end

    # Verifies a token produced by `generate_token_for_payload` and returns its
    # decoded payload, or `nil` if the signature does not verify or the token is
    # malformed. Does not check purpose/expiry/data — `find_by_token_for` layers
    # those on top.
    def verify_token_for_payload(token : String) : Hash(String, JSON::Any)?
      json = Grant::Signer.open(token, token_for_signing_context)
      return nil unless json
      JSON.parse(json).as_h?
    rescue JSON::ParseException
      nil
    end

    private def token_for_payload(purpose : Symbol, token : String) : Grant::Signer::Payload?
      payload = Grant::Signer.open_payload(token, token_for_signing_context)
      return nil unless payload
      return nil unless payload.purpose == purpose.to_s
      return nil if payload.expired?
      return nil unless token_for_definitions[purpose]?
      payload
    end

    private def find_token_record(payload : Grant::Signer::Payload) : self?
      # IDs are encoded as strings in the token payload. Restore integer
      # bindings before querying so PostgreSQL and SQLite compare like types.
      find(payload.id.to_i64? || payload.id)
    end

    private def token_data_current?(purpose : Symbol, record : self, payload : Grant::Signer::Payload) : Bool
      definition = token_for_definitions[purpose]
      definition.block.call(record) == payload.data
    end

    private def token_for_signing_context : String
      "token_for/#{table_name}"
    end

    private def record_for_token(purpose : Symbol, token : String) : self?
      payload = token_for_payload(purpose, token)
      return nil unless payload
      record = find_token_record(payload)
      return nil unless record
      token_data_current?(purpose, record, payload) ? record : nil
    end
  end
end
