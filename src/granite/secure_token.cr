require "random/secure"
require "base64"

module Granite
  module SecureToken
    macro has_secure_token(name, length = 24, alphabet = :base58)
      column {{ name.id }} : String?
      
      def regenerate_{{ name.id }}
        self.{{ name.id }} = Granite::SecureToken.generate_secure_token(
          length: {{ length }},
          alphabet: {{ alphabet }}
        )
      end
      
      before_create :generate_{{ name.id }}_if_needed
      
      private def generate_{{ name.id }}_if_needed
        if self.{{ name.id }}.nil?
          self.{{ name.id }} = Granite::SecureToken.generate_secure_token(
            length: {{ length }},
            alphabet: {{ alphabet }}
          )
        end
      end
    end
    
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