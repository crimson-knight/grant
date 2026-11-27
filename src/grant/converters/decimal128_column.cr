module Grant::Converters
  # Stores a `Grant::Decimal128` column declared with `precision:` *P* and
  # `scale:` *S*. Every value is kept at scale *S* exactly; nothing rounds.
  #
  # | Database   | Column type               | Stored form                          |
  # |------------|---------------------------|--------------------------------------|
  # | PostgreSQL | `NUMERIC(P, S)`           | the plain decimal text               |
  # | MySQL      | `DECIMAL(P, S)`           | the plain decimal text               |
  # | SQLite     | `INTEGER` when P <= 18    | the coefficient at scale S (`Int64`) |
  # | SQLite     | `TEXT` when 19 <= P <= 38 | the plain decimal text at scale S    |
  #
  # SQLite's own NUMERIC keeps about 15 significant digits, so Grant stores a
  # form that keeps every digit. Columns typed `Grant::Decimal128` use this
  # converter without declaring it.
  module Decimal128Column(P, S)
    extend self

    # Whether SQLite keeps this column as an `INTEGER` coefficient.
    def stored_as_integer? : Bool
      P <= 18
    end

    def to_db(value : Grant::Decimal128?) : Grant::Columns::Type
      return if value.nil?
      Grant::StoredDecimal.new(at_column_scale(value), stored_as_integer?)
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : Grant::Decimal128?
      case value
      when Grant::StoredDecimal then value.decimal
      when Grant::Decimal128    then at_column_scale(value)
      when String               then parse(value)
      when Int                  then integer_from_db(value)
      end
    end

    def from_rs(result : ::DB::ResultSet) : Grant::Decimal128?
      # MySQL hands a DECIMAL over as its exact text through
      # `read_keeping_decimal_text` (see src/adapter/mysql.cr); the driver
      # alone would round it to a Float64.
      value = result.responds_to?(:read_keeping_decimal_text) ? result.read_keeping_decimal_text : result.read
      case value
      when Nil    then nil
      when Int    then integer_from_db(value)
      when String then parse(value)
      when Bytes  then parse(String.new(value))
      when Float
        raise ArgumentError.new("A Grant::Decimal128 column read a floating-point value (#{value}); its stored form is lost")
      else
        # PostgreSQL returns `Grant::PG::Numeric`, which prints as its exact decimal.
        parse(value.to_s)
      end
    end

    # *value* at the column scale. Raises `Grant::Decimal128::InexactError`
    # when that would drop a nonzero digit.
    def at_column_scale(value : Grant::Decimal128) : Grant::Decimal128
      value.rescale(S)
    end

    # Parses decimal text read from the database at the column scale.
    def parse(text : String) : Grant::Decimal128
      at_column_scale(Grant::Decimal128.parse(text.strip))
    end

    # An integer read from the database: the coefficient at scale S when
    # SQLite keeps the column as an `INTEGER`; a whole number otherwise.
    private def integer_from_db(value : Int) : Grant::Decimal128
      if stored_as_integer?
        Grant::Decimal128.new(value.to_i128, S)
      else
        at_column_scale(Grant::Decimal128.new(value.to_i128))
      end
    end

    # The reason *value* cannot be stored exactly in this column, or nil when
    # it can.
    def reason_value_does_not_fit(value : Grant::Decimal128) : String?
      unless value.scale <= S || value.rescale(S, :truncate) == value
        return "has scale #{S}, and #{value} has more fractional digits; round it first (Grant never rounds)"
      end
      integer_digits = value.rescale(0, :truncate).precision
      integer_digits = 0 if value.rescale(0, :truncate).zero?
      if integer_digits > P - S
        "has precision #{P} and scale #{S} (#{P - S} digits before the point), and #{value} does not fit"
      end
    end

    # The value a query on this column binds for *value* on *adapter*.
    def bind_value(value : Grant::Decimal128, adapter : Grant::Adapter::Base) : Grant::Columns::Type
      stored = Grant::StoredDecimal.new(at_column_scale(value), stored_as_integer?)
      adapter.sqlite? ? stored.sqlite_bind_value : stored.decimal.to_s
    end

    # The values an `IN` condition on this column binds for *values*.
    def bind_values(values : Array(Grant::Decimal128), adapter : Grant::Adapter::Base) : Array(Int64) | Array(String)
      if adapter.sqlite? && stored_as_integer?
        values.map { |value| at_column_scale(value).coefficient.to_i64 }
      else
        values.map { |value| at_column_scale(value).to_s }
      end
    end
  end

  # Stores the amount of a `Grant::Money` column like `Decimal128Column(P, S)`.
  # The currency lives in the companion column `<name>_currency`, or is fixed
  # by the column's `currency:` option; the model composes the two (see
  # `Grant::Columns.column`).
  module MoneyColumn(P, S)
    extend self

    def to_db(value : Grant::Money?) : Grant::Columns::Type
      return if value.nil?
      Grant::StoredDecimal.new(Decimal128Column(P, S).at_column_scale(value.amount), Decimal128Column(P, S).stored_as_integer?, value.currency.code)
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : Grant::Money?
      if value.is_a?(Grant::StoredDecimal)
        if code = value.currency_code
          Grant::Money.new(value.decimal, code)
        end
      end
    end
  end
end

abstract class Grant::Adapter::Base
  # Binds a `Grant::StoredDecimal` (a decimal column's value) as its plain
  # decimal text, which NUMERIC and DECIMAL columns take exactly.
  def normalize_bind_value(value : Grant::StoredDecimal) : String
    value.decimal.to_s
  end

  # Binds a `Grant::Decimal128` as its plain decimal text.
  def normalize_bind_value(value : Grant::Decimal128) : String
    value.to_s
  end

  # Binds a `Grant::Money` as the plain text of its amount.
  def normalize_bind_value(value : Grant::Money) : String
    value.amount.to_s
  end
end

module Grant::Type
  # Converts decimal text ("19.99") to a `Grant::Decimal128`; invalid text
  # raises `ArgumentError`, which mass assignment reports as a conversion error.
  def convert_type(value : String, type : Grant::Decimal128.class) : Grant::Decimal128
    decimal_from_text(value)
  end

  # :ditto:
  def convert_type(value : String, type : Grant::Decimal128?.class) : Grant::Decimal128?
    decimal_from_text(value)
  end

  # Integers become exact decimals.
  def convert_type(value : Int, type : Grant::Decimal128.class) : Grant::Decimal128
    Grant::Decimal128.new(value.to_i128)
  end

  # :ditto:
  def convert_type(value : Int, type : Grant::Decimal128?.class) : Grant::Decimal128?
    Grant::Decimal128.new(value.to_i128)
  end

  # A float becomes the decimal of its shortest printed form (`0.1` is 0.1).
  def convert_type(value : Float, type : Grant::Decimal128.class) : Grant::Decimal128
    decimal_from_text(value.to_s)
  end

  # :ditto:
  def convert_type(value : Float, type : Grant::Decimal128?.class) : Grant::Decimal128?
    decimal_from_text(value.to_s)
  end

  private def decimal_from_text(text : String) : Grant::Decimal128
    Grant::Decimal128.parse?(text.strip) || raise ArgumentError.new("Invalid decimal: #{text.inspect}")
  end
end
