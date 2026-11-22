require "big"
require "big/json"

module Grant::Converters
  # Stores a `BigDecimal` as exact decimal text. PostgreSQL and MySQL keep it
  # in a `NUMERIC`/`DECIMAL` column (`precision:` and `scale:` on the column
  # shape the type); SQLite keeps it in a `NUMERIC` column, which holds
  # about 15 significant digits exactly. Columns typed `BigDecimal` use it
  # without declaring a converter.
  module Decimal
    extend self

    def to_db(value : ::BigDecimal?) : Grant::Columns::Type
      return if value.nil?
      value.to_s
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : ::BigDecimal?
      case value
      when ::BigDecimal then value
      when String       then parse(value)
      when Int, Float   then ::BigDecimal.new(value.to_s)
      end
    end

    def from_rs(result : ::DB::ResultSet) : ::BigDecimal?
      value = result.read
      case value
      when Nil          then nil
      when ::BigDecimal then value
      when String       then parse(value)
      when Int          then ::BigDecimal.new(value)
      when Float        then ::BigDecimal.new(value.to_s)
      when Bytes        then parse(String.new(value))
      else
        # PostgreSQL returns `Grant::PG::Numeric`, which prints as its exact decimal.
        parse(value.to_s)
      end
    end

    # Parses decimal text, raising `ArgumentError` for anything else.
    def parse(text : String) : ::BigDecimal
      ::BigDecimal.new(text.strip)
    rescue InvalidBigDecimalException
      raise ArgumentError.new("Invalid decimal: #{text.inspect}")
    end
  end
end

abstract class Grant::Adapter::Base
  # Binds a `BigDecimal` as exact decimal text; every driver casts it to the
  # column's numeric type.
  def normalize_bind_value(value : ::BigDecimal) : String
    value.to_s
  end
end

module Grant::Type
  # Converts decimal text to a `BigDecimal`; invalid text raises
  # `ArgumentError`, which mass assignment reports as a conversion error.
  def convert_type(value : String, type : BigDecimal.class) : BigDecimal
    Grant::Converters::Decimal.parse(value)
  end

  # :ditto:
  def convert_type(value : String, type : BigDecimal?.class) : BigDecimal?
    Grant::Converters::Decimal.parse(value)
  end

  # Integers and floats become exact decimals.
  def convert_type(value : Int | Float, type : BigDecimal.class) : BigDecimal
    BigDecimal.new(value.to_s)
  end

  # :ditto:
  def convert_type(value : Int | Float, type : BigDecimal?.class) : BigDecimal?
    BigDecimal.new(value.to_s)
  end
end
