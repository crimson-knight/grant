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
  # Binds an `Int8` or `Int16` as `Int64`, which every driver accepts.
  def normalize_bind_value(value : ::Int8 | ::Int16) : Int64
    value.to_i64
  end
end
