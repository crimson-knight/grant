require "json"
require "base64"
require "openssl/hmac"

module Granite::TokenFor
  macro included
    extend ClassMethods
    
    class_getter token_for_definitions = {} of Symbol => TokenForDefinition
    
    struct TokenForDefinition
      getter expires_in : Time::Span?
      getter block : Proc(Granite::Base, String)
      
      def initialize(@expires_in : Time::Span?, @block : Proc(Granite::Base, String))
      end
    end
  end
  
  def generate_token_for(purpose : Symbol) : String
    definition = self.class.token_for_definitions[purpose]?
    raise "No token_for definition for purpose: #{purpose}" unless definition
    
    # Generate data for token uniqueness
    unique_data = definition.block.call(self)
    
    payload = {
      "id" => self.id.to_s,
      "purpose" => purpose.to_s,
      "data" => unique_data,
      "expires_at" => definition.expires_in ? (Time.utc + definition.expires_in).to_unix : nil
    }
    
    self.class.generate_token_for_payload(payload)
  end
  
  module ClassMethods
    macro generates_token_for(purpose, expires_in = nil, &block)
      {% if block %}
        self.token_for_definitions[{{ purpose }}] = TokenForDefinition.new(
          expires_in: {{ expires_in }},
          block: ->(record : Granite::Base) do
            instance = record.as(self)
            {% if block.args.empty? %}
              instance.instance_exec do
                {{ block.body }}
              end.to_s
            {% else %}
              {{ block.body }}.to_s
            {% end %}
          end
        )
      {% else %}
        raise "generates_token_for requires a block"
      {% end %}
    end
    
    def find_by_token_for(purpose : Symbol, token : String) : self?
      payload = verify_token_for_payload(token)
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
      
      record = find(id)
      return nil unless record
      
      # Verify data hasn't changed
      definition = token_for_definitions[purpose]?
      return nil unless definition
      
      current_data = definition.block.call(record)
      stored_data = payload["data"]?.try(&.as_s)
      
      return nil unless current_data == stored_data
      
      record
    rescue
      nil
    end
    
    def generate_token_for_payload(payload : Hash(String, String | Int64 | Nil)) : String
      json = payload.to_json
      signature = generate_token_signature(json)
      
      data = {
        "data" => Base64.urlsafe_encode(json, padding: false),
        "signature" => signature
      }
      
      Base64.urlsafe_encode(data.to_json, padding: false)
    end
    
    def verify_token_for_payload(token : String) : Hash(String, JSON::Any)?
      # Decode outer wrapper
      wrapper_json = Base64.urlsafe_decode_string(token)
      wrapper = JSON.parse(wrapper_json)
      
      # Extract data and signature
      data = wrapper["data"].as_s
      signature = wrapper["signature"].as_s
      
      # Decode and verify
      json = Base64.urlsafe_decode_string(data)
      
      # Verify signature
      expected_signature = generate_token_signature(json)
      return nil unless secure_token_compare(signature, expected_signature)
      
      JSON.parse(json).as_h
    rescue
      nil
    end
    
    private def generate_token_signature(data : String) : String
      secret = token_signing_secret
      Base64.urlsafe_encode(
        OpenSSL::HMAC.digest(:sha256, secret, data),
        padding: false
      )
    end
    
    private def token_signing_secret : String
      # In a real app, this should come from environment or config
      ENV["GRANITE_SIGNING_SECRET"]? || raise "GRANITE_SIGNING_SECRET not set"
    end
    
    private def secure_token_compare(a : String, b : String) : Bool
      return false unless a.bytesize == b.bytesize
      
      result = 0_u8
      a.bytes.zip(b.bytes) do |byte_a, byte_b|
        result |= byte_a ^ byte_b
      end
      
      result == 0
    end
  end
end