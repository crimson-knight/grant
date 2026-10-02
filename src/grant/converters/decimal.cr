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
        # PostgreSQL returns `PG::Numeric`, which prints as its exact decimal.
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

module Grant::Converters
  # Stores an integer (*T*) as an `Int64`, whatever width its column has. The
  # drivers bind and read nothing narrower than `Int16`, and a database
  # returns the width of the column (`SMALLINT` is an `Int16`), which a
  # differently sized model type would reject. Columns typed `Int8` or `Int16`,
  # and `Int32`/`Int64` columns with a `limit:`, use it without declaring a
  # converter.
  module SmallInteger(T)
    extend self

    def to_db(value : T?) : Grant::Columns::Type
      value.try(&.to_i64)
    end

    # The model value for a stored value (what dirty tracking keeps).
    def from_db(value) : T?
      case value
      when Int then T.new(value)
      end
    end

    def from_rs(result : ::DB::ResultSet) : T?
      value = result.read
      case value
      when Nil then nil
      when Int then T.new(value)
      else
        raise ArgumentError.new("Cannot read #{value.class} as #{T}")
      end
    end
  end
end

abstract class Grant::Adapter::Base
  # Binds a `BigDecimal` as exact decimal text; every driver casts it to the
  # column's numeric type.
  def normalize_bind_value(value : ::BigDecimal) : String
    value.to_s
  end

  # Binds an `Int8` or `Int16` as `Int64`, which every driver accepts.
  def normalize_bind_value(value : ::Int8 | ::Int16) : Int64
    value.to_i64
  end
end
