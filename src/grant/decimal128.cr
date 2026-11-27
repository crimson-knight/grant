require "./vendor/decimal/mica/decimal"
require "./vendor/decimal/mica/decimal/json"
require "./vendor/decimal/mica/decimal/yaml"

module Grant
  # An exact decimal of up to 38 digits (Mica's `Decimal128`, vendored under
  # `Grant::Mica`). Needs no C library and no `big`, so it is always available.
  #
  # ```
  # class Product < Grant::Base
  #   column id : Int64, primary: true
  #   column price : Grant::Decimal128, precision: 12, scale: 2
  # end
  # ```
  alias Decimal128 = Grant::Mica::Decimal128

  # An ISO 4217 currency with its minor-unit count (Mica's `Currency`).
  alias Currency = Grant::Mica::Currency

  # A `Decimal128` amount in one `Currency` (Mica's `Money`).
  alias Money = Grant::Mica::Money

  # Raised when a value assigned to a `Grant::Decimal128` or `Grant::Money`
  # column cannot be stored exactly: it has more fractional digits than the
  # column's `scale:` or more digits than its `precision:`, or it is a `Money`
  # in a currency other than the column's fixed `currency:`. Grant never
  # rounds such a value. Mass assignment (`new`, `set_attributes`,
  # `update`) reports it as a conversion error on the record instead, so
  # `save` returns false with the message in `errors`.
  class DecimalColumnError < ArgumentError
    def initialize(model_name : String, column_name : String, reason : String)
      super("#{model_name}##{column_name} #{reason}")
    end
  end

  # The database form of a `Grant::Decimal128` or `Grant::Money` column value:
  # the amount at the column's scale, how SQLite keeps it, and (for `Money`)
  # the currency code, which dirty tracking compares but no driver binds.
  #
  # PostgreSQL and MySQL bind the plain decimal text, which their NUMERIC and
  # DECIMAL columns take exactly. SQLite binds the coefficient as an `Int64`
  # for an `INTEGER` column (precision up to 18) and the plain text for a
  # `TEXT` column (precision 19 to 38).
  struct StoredDecimal
    getter decimal : Grant::Decimal128
    getter? stored_as_integer : Bool
    getter currency_code : String?

    def initialize(@decimal : Grant::Decimal128, @stored_as_integer : Bool, @currency_code : String? = nil)
    end

    # The value SQLite binds: the coefficient for an `INTEGER` column, the
    # plain decimal text for a `TEXT` column.
    def sqlite_bind_value : Int64 | String
      stored_as_integer? ? decimal.coefficient.to_i64 : decimal.to_s
    end

    def to_s(io : IO) : Nil
      decimal.to_s(io)
    end

    # The plain decimal text, as a JSON string.
    def to_json(json : JSON::Builder) : Nil
      decimal.to_json(json)
    end

    # The plain decimal text, as a YAML scalar.
    def to_yaml(yaml : YAML::Nodes::Builder) : Nil
      decimal.to_yaml(yaml)
    end
  end
end

# Mica's decimal component gives `Decimal128` its JSON and YAML forms but
# leaves `Money` without one, since the shape of a money value on the wire
# is the caller's choice. Grant writes a Money column as an object of the
# plain amount text and the currency code, `{"amount": "12.30",
# "currency": "USD"}`, and reads the same object back.
struct Grant::Mica::Money
  # Reads `{"amount": …, "currency": "USD"}`. The amount may be a JSON
  # string or number (see `Decimal128.new(JSON::PullParser)`).
  def self.new(pull : ::JSON::PullParser) : Money
    location = pull.location
    amount = nil
    currency_code = nil
    pull.read_object do |key|
      case key
      when "amount"   then amount = Decimal128.new(pull)
      when "currency" then currency_code = pull.read_string
      else                 pull.skip
      end
    end
    unless amount && currency_code
      raise ::JSON::ParseException.new("Expected a money object with \"amount\" and \"currency\"", *location)
    end
    currency = Currency.find?(currency_code) || raise ::JSON::ParseException.new("Unknown currency: #{currency_code.inspect}", *location)
    new(amount, currency)
  end

  # Writes `{"amount": "12.30", "currency": "USD"}`.
  def to_json(json : ::JSON::Builder) : Nil
    json.object do
      json.field "amount", amount.to_s
      json.field "currency", currency.code
    end
  end

  # Reads a mapping with `amount` and `currency` keys.
  def self.new(context : ::YAML::ParseContext, node : ::YAML::Nodes::Node) : Money
    mapping = Hash(String, String).new(context, node)
    amount_text = mapping["amount"]? || node.raise "Expected a money mapping with an amount"
    currency_code = mapping["currency"]? || node.raise "Expected a money mapping with a currency"
    amount = Decimal128.parse?(amount_text) || node.raise "Expected a decimal amount, not #{amount_text.inspect}"
    currency = Currency.find?(currency_code) || node.raise "Unknown currency: #{currency_code.inspect}"
    new(amount, currency)
  end

  # Writes a mapping with `amount` and `currency` keys.
  def to_yaml(yaml : ::YAML::Nodes::Builder) : Nil
    yaml.mapping do
      yaml.scalar "amount"
      yaml.scalar amount.to_s
      yaml.scalar "currency"
      yaml.scalar currency.code
    end
  end
end
