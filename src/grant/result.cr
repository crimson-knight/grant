module Grant
  # Buffered rows returned by `Grant::Connection#exec_query` and
  # `#select_all`.
  #
  # Column names preserve database order. Each row is available as positional
  # values through `#rows`, or as a `Hash(String, DB::Any)` through `#each` and
  # `#to_a`.
  class Result
    alias Row = Array(DB::Any)
    alias HashRow = Hash(String, DB::Any)

    getter columns : Array(String)
    getter rows : Array(Row)

    def initialize(@columns : Array(String), @rows : Array(Row))
    end

    # Builds a buffered result from a positioned database result set.
    def self.from(result_set : DB::ResultSet) : self
      columns = result_set.column_names
      rows = [] of Row

      result_set.each do
        row = [] of DB::Any
        result_set.column_count.times do
          row << result_set.read.as(DB::Any)
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

    # Returns all rows as `Array(Hash(String, DB::Any))`.
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
      values = {} of String => DB::Any
      columns.each_with_index do |column, index|
        values[column] = row[index]
      end
      values
    end
  end
end
