require "json"
require "base64"
require "openssl/hmac"

# Tamper-proof, optionally expiring signed IDs for a model record, in the style
# of Rails' `signed_id`.
#
# A signed ID encodes a record's primary key together with a *purpose* and an
# optional expiry, all protected by an HMAC-SHA256 signature. It is safe to put in
# a URL or email (e.g. a password-reset or email-confirmation link): the recipient
# cannot forge or alter it, and `find_signed` only returns the record when the
# signature, purpose, and (if set) expiry all check out.
#
# This module is **opt-in** — `include Grant::SignedId` in the models that need
# it. The signing secret is read from the `GRANT_SIGNING_SECRET` environment
# variable; generating or verifying a token without it raises.
#
# ```
# ENV["GRANT_SIGNING_SECRET"] = "a-long-random-secret"
#
# class User < Grant::Base
#   include Grant::SignedId
#   column id : Int64, primary: true
# end
#
# user = User.create
# token = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)
#
# # later, from the link:
# User.find_signed(token, purpose: :password_reset)     # => the user
# User.find_signed(token, purpose: :email_confirmation) # => nil (wrong purpose)
# ```
module Grant::SignedId
  macro included
    extend ClassMethods
  end

  # Returns a signed, URL-safe token encoding this record's id, the given
  # *purpose*, and an optional expiry.
  #
  # The token is bound to *purpose*, so a token minted for `:password_reset`
  # cannot be redeemed for `:email_confirmation`. When *expires_in* is given, the
  # token is rejected by `find_signed` after that span elapses; when `nil`
  # (default), it never expires. Requires `GRANT_SIGNING_SECRET` to be set.
  #
  # ```
  # ENV["GRANT_SIGNING_SECRET"] = "secret"
  # user.signed_id(purpose: :password_reset)                     # never expires
  # user.signed_id(purpose: :password_reset, expires_in: 1.hour) # 1-hour window
  # ```
  def signed_id(purpose : Symbol, expires_in : Time::Span? = nil) : String
    payload = {
      "id"         => self.id.to_s,
      "purpose"    => purpose.to_s,
      "expires_at" => expires_in ? (Time.utc + expires_in).to_unix : nil,
    }

    self.class.generate_signed_token(payload)
  end

  # Class-level entry points for `Grant::SignedId`, mixed in via `extend
  # ClassMethods` when a model does `include Grant::SignedId`.
  module ClassMethods
    # Finds and returns the record referenced by *signed_id*, or `nil` if the
    # token is invalid for *purpose*.
    #
    # Returns `nil` (never raises) when the signature does not verify, the
    # *purpose* does not match the one the token was minted with, the token has
    # expired, or no record with the encoded id exists. This is the verification
    # counterpart to the instance `#signed_id`. Requires `GRANT_SIGNING_SECRET`.
    #
    # ```
    # ENV["GRANT_SIGNING_SECRET"] = "secret"
    # token = user.signed_id(purpose: :password_reset, expires_in: 15.minutes)
    #
    # User.find_signed(token, purpose: :password_reset)     # => the user
    # User.find_signed("garbage", purpose: :password_reset) # => nil
    # ```
    def find_signed(signed_id : String, purpose : Symbol) : self?
      payload = verify_signed_token(signed_id)
      return nil unless payload

      # Check purpose
      return nil unless payload["purpose"]? == purpose.to_s

      # Check expiration
      if expires_at = payload["expires_at"]?
        return nil if expires_at.as_i64 < Time.utc.to_unix
      end

      # Find record
      id = payload["id"]?.try(&.as_s)
      return nil unless id

      find(id)
    rescue
      nil
    end

    # Serializes *payload* to JSON, signs it with HMAC-SHA256, and returns the
    # Base64-url-encoded `{data, signature}` envelope. Low-level building block for
    # `#signed_id`; prefer that method. Requires `GRANT_SIGNING_SECRET`.
    #
    # ```
    # ENV["GRANT_SIGNING_SECRET"] = "secret"
    # User.generate_signed_token({"id" => "1", "purpose" => "x", "expires_at" => nil})
    # ```
    def generate_signed_token(payload : Hash(String, String | Int64 | Nil)) : String
      json = payload.to_json
      signature = generate_signature(json)

      data = {
        "data"      => Base64.urlsafe_encode(json, padding: false),
        "signature" => signature,
      }

      Base64.urlsafe_encode(data.to_json, padding: false)
    end

    # Verifies a token produced by `generate_signed_token` and returns its decoded
    # payload as a `Hash(String, JSON::Any)`, or `nil` if the signature does not
    # verify or the token is malformed. Does not check purpose/expiry —
    # `find_signed` layers those on top. Requires `GRANT_SIGNING_SECRET`.
    #
    # ```
    # ENV["GRANT_SIGNING_SECRET"] = "secret"
    # tok = user.signed_id(purpose: :x)
    # User.verify_signed_token(tok).try(&.["purpose"]) # => "x"
    # ```
    def verify_signed_token(token : String) : Hash(String, JSON::Any)?
      # Decode outer wrapper
      wrapper_json = String.new(Base64.decode(token))
      wrapper = JSON.parse(wrapper_json)

      # Extract data and signature
      data = wrapper["data"].as_s
      signature = wrapper["signature"].as_s

      # Decode and verify
      json = String.new(Base64.decode(data))

      # Verify signature
      expected_signature = generate_signature(json)
      return nil unless secure_compare(signature, expected_signature)

      JSON.parse(json).as_h
    rescue
      nil
    end

    private def generate_signature(data : String) : String
      secret = signing_secret
      Base64.urlsafe_encode(
        OpenSSL::HMAC.digest(:sha256, secret, data),
        padding: false
      )
    end

    private def signing_secret : String
      # In a real app, this should come from environment or config
      ENV["GRANT_SIGNING_SECRET"]? || raise "GRANT_SIGNING_SECRET not set"
    end

    private def secure_compare(a : String, b : String) : Bool
      return false unless a.bytesize == b.bytesize

      result = 0_u8
      a.bytes.zip(b.bytes) do |byte_a, byte_b|
        result |= byte_a ^ byte_b
      end

      result == 0
    end
  end
end
