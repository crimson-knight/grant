require "json"

module Grant::Encryption
  # Turns an attribute value into the String that gets encrypted and back, so
  # `encrypts balance : Int64` or `encrypts settings : JSON::Any` share the
  # String-based cipher. Times are stored as nanosecond-precision UTC RFC 3339;
  # anything else that is not a scalar goes through JSON.
  module Serializer
    def self.dump(value) : String
      if value.is_a?(String)
        value
      elsif value.is_a?(Int) || value.is_a?(Float) || value.is_a?(Bool) || value.is_a?(UUID)
        value.to_s
      elsif value.is_a?(Time)
        value.to_utc.to_rfc3339(fraction_digits: 9)
      elsif value.is_a?(Bytes) || value.nil?
        raise UnsupportedTypeError.new("Binary and nil values cannot be encrypted attributes")
      else
        value.to_json
      end
    end

    def self.load(raw : String, type : T.class) : T forall T
      {% if T == String %}
        raw
      {% elsif T <= Int %}
        T.new(raw.to_i64)
      {% elsif T <= Float %}
        T.new(raw.to_f64)
      {% elsif T == Bool %}
        raw == "true"
      {% elsif T == Time %}
        Time.parse_rfc3339(raw)
      {% else %}
        T.from_json(raw)
      {% end %}
    end
  end
end
