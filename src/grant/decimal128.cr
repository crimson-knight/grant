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
