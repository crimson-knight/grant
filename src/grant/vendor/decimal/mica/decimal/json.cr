require "json"
require "../decimal"

# JSON for `Grant::Mica::Decimal128` (opt-in: `require "mica/decimal/json"`).
#
# A value is written as a JSON string in its plain form (`"12.30"`), so no
# reader turns it into a binary float. Reading accepts a JSON string, or an
# integer or float token parsed from its text, so `12.30` keeps its digits.
#
# ```
# Grant::Mica::Decimal128.parse("12.30").to_json    # => "\"12.30\""
# Grant::Mica::Decimal128.from_json(%(12.30)).scale # => 2
# ```
module Grant::Mica
  struct Decimal128
    # Reads a JSON string, integer or float. Raises `JSON::ParseException`
    # for any other token and `Decimal128::ParseError` or `OverflowError`
    # for text that is not a decimal of up to 38 digits.
    def self.new(pull : ::JSON::PullParser) : Decimal128
      case pull.kind
      when .string?
        parse(pull.read_string)
      when .int?, .float?
        parse(pull.read_raw)
      else
        pull.raise "Expected a decimal string or number, not #{pull.kind}"
      end
    end

    # Writes the plain form as a JSON string.
    def to_json(json : ::JSON::Builder) : Nil
      json.string(to_s)
    end

    # Writes the plain form as an object key.
    def to_json_object_key : String
      to_s
    end
  end
end
