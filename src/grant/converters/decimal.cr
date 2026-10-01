require "big"

module Grant::Converters
  # Stores a `BigDecimal` as exact decimal text. PostgreSQL and MySQL keep it
  # in a `NUMERIC`/`DECIMAL` column (`precision:` and `scale:` on the column
  # shape the type); SQLite keeps it in a `NUMERIC` column, which holds
  # about 15 significant digits exactly. Columns typed `BigDecimal` use it
  # without declaring a converter.
  module Decimal
    extend self

    def to_db(value : ::BigDecimal?) : Grant::Columns::Type
      return nil if value.nil?
      value.to_s
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : ::BigDecimal?
      case value
      when ::BigDecimal then value
      when String       then parse(value)
      when Int, Float   then ::BigDecimal.new(value.to_s)
      else                   nil
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
        # PostgreSQL returns `PG::Numeric`, which prints as its exact decimal.
        parse(value.to_s)
      end
    end

    # Parses decimal text, raising `ArgumentError` for anything else.
    def parse(text : String) : ::BigDecimal
      ::BigDecimal.new(text.strip)
    rescue ex : InvalidBigDecimalException
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
