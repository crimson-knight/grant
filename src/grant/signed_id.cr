require "json"
require "base64"
require "openssl/hmac"

module Grant::SignedId
  macro included
    extend ClassMethods
  end
  
  def signed_id(purpose : Symbol, expires_in : Time::Span? = nil) : String
    payload = {
      "id" => self.id.to_s,
      "purpose" => purpose.to_s,
      "expires_at" => expires_in ? (Time.utc + expires_in).to_unix : nil
    }
    
    self.class.generate_signed_token(payload)
  end
  
  module ClassMethods
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
    
    def generate_signed_token(payload : Hash(String, String | Int64 | Nil)) : String
      json = payload.to_json
      signature = generate_signature(json)
      
      data = {
        "data" => Base64.urlsafe_encode(json, padding: false),
        "signature" => signature
      }
      
      Base64.urlsafe_encode(data.to_json, padding: false)
    end
    
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
      ENV["GRANITE_SIGNING_SECRET"]? || raise "GRANITE_SIGNING_SECRET not set"
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