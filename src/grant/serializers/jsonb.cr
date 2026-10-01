require "json"
require "./json"

module Grant::Serializers
  # JSONB uses the same serialization as JSON. The storage difference (a
  # native jsonb column on PostgreSQL, JSON text elsewhere) is decided by the
  # column type, not by the serializer.
  class JSONB < JSON
  end
end

module Grant::Converters
  # Stores a `JSON::Any` document. PostgreSQL keeps it in a native `jsonb`
  # column; SQLite and MySQL keep the JSON text. Columns typed `JSON::Any`
  # use it without declaring a converter.
  module JsonDocument
    extend self

    def to_db(value : ::JSON::Any?) : Grant::Columns::Type
      return nil if value.nil?
      value.to_json
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : ::JSON::Any?
      case value
      when String then ::JSON.parse(value)
      when Slice  then ::JSON.parse(String.new(value))
      else             nil
      end
    end

    def from_rs(result : ::DB::ResultSet) : ::JSON::Any?
      value = result.read
      case value
      when Nil                then nil
      when String             then ::JSON.parse(value)
      when ::JSON::Any        then value
      when ::JSON::PullParser then ::JSON::Any.new(value)
      when Bytes              then ::JSON.parse(String.new(value))
      else
        raise ArgumentError.new("Cannot read #{value.class} as a JSON document")
      end
    end
  end
end
