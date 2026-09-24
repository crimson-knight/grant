module Grant
  # Buffered rows returned by `Grant::Connection#exec_query` and
  # `#select_all`.
  #
  # Values use a stable core union across adapter load orders. PostgreSQL
  # numerics, intervals, geometric values, and arrays are normalized by its
  # adapter to strings; JSON parser values become `JSON::Any`. `Model.scalar`
  # keeps the driver's native scalar value.
  #
  # Column names preserve database order. Rows are available positionally
  # through `#rows`, or as a string-keyed hash through `#each` and `#to_a`.
  #
  # ```
  # result = Grant.connection.exec_query("SELECT id, name FROM users")
  # result.each { |row| puts row["name"] }
  # ```
  class Result
    alias CoreValue = DB::Any | Int8 | Int16 | UInt8 | UInt16 | UInt32 | UUID | JSON::Any | Time::Span |
                      Array(String) | Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) |
                      Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                      Array(Float32) | Array(Float64) | Array(Bool) | Array(UUID) | Array(JSON::Any)

    alias Value = CoreValue | Char | UInt64

    alias Row = Array(Value)
    alias HashRow = Hash(String, Value)

    class UnsupportedValueError < Grant::ErrorBase
      def initialize(value_class_name : String)
        super("Database result type #{value_class_name} is not supported by Grant::Result::Value")
      end
    end

    # :nodoc:
    def self.integer_count(value) : Int64
      return 0_i64 if value.nil?

      case value
      when Int8, Int16, Int32, Int64
        value.to_i64
      when UInt8, UInt16, UInt32, UInt64
        value.to_i64
      when Float32, Float64
        value.to_i64
      when String
        integer_count_from_string(value)
      else
        integer = integer_count_from_string(value.to_s)
        integer
      end
    end

    private def self.integer_count_from_string(value : String) : Int64
      value.to_i64? || value.to_f64?.try(&.to_i64) ||
        raise ArgumentError.new("count_by_sql did not return a numeric value")
    end

    # :nodoc:
    def self.normalize(value : Value) : Value
      value
    end

    # :nodoc:
    def self.normalize(value) : Value
      raise UnsupportedValueError.new(value.class.name)
    end

    getter columns : Array(String)
    getter rows : Array(Row)

    def initialize(@columns : Array(String), @rows : Array(Row))
    end

    # Builds a buffered result from a positioned database result set.
    def self.from(result_set : DB::ResultSet, adapter : Grant::Adapter::Base) : self
      columns = result_set.column_names
      rows = [] of Row

      result_set.each do
        row = [] of Value
        result_set.column_count.times do
          row << adapter.normalize_result_value(result_set.read)
        end
        rows << row
      end

      new(columns, rows)
    end

    # Iterates over each row as a string-keyed hash.
    def each(& : HashRow ->) : Nil
      rows.each do |row|
        yield hash_row(row)
      end
    end

    # Returns all rows as `Array(Hash(String, Value))`.
    def to_a : Array(HashRow)
      rows.map { |row| hash_row(row) }
    end

    # Returns the number of buffered rows.
    def size : Int32
      rows.size
    end

    # Returns `true` when no rows were returned.
    def empty? : Bool
      rows.empty?
    end

    private def hash_row(row : Row) : HashRow
      values = {} of String => Value
      columns.each_with_index do |column, index|
        values[column] = row[index]
      end
      values
    end
  end
end
