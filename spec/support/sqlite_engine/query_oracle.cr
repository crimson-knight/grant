require "./sql_oracle"

# C SQLite run as the reference for query results: open a database file,
# run statements, and read typed rows, for comparison with
# `Grant::SQLiteEngine::Query`. Links libsqlite3, so only specs and scripts
# load it.
module SQLiteQueryOracle
  alias Value = Grant::SQLiteEngine::Value

  # The C functions SQLiteSQLOracle::LibOracle does not already bind, on its
  # handle types.
  @[Link("sqlite3")]
  lib LibQueryOracle
    alias Database = SQLiteSQLOracle::LibOracle::Database
    alias Statement = SQLiteSQLOracle::LibOracle::Statement

    fun reset = sqlite3_reset(statement : Statement) : Int32
    fun column_name = sqlite3_column_name(statement : Statement, column : Int32) : UInt8*
    fun column_type = sqlite3_column_type(statement : Statement, column : Int32) : Int32
    fun column_int64 = sqlite3_column_int64(statement : Statement, column : Int32) : Int64
    fun column_double = sqlite3_column_double(statement : Statement, column : Int32) : Float64
    fun column_blob = sqlite3_column_blob(statement : Statement, column : Int32) : Void*
    fun column_bytes = sqlite3_column_bytes(statement : Statement, column : Int32) : Int32
    fun bind_parameter_count = sqlite3_bind_parameter_count(statement : Statement) : Int32
    fun bind_null = sqlite3_bind_null(statement : Statement, index : Int32) : Int32
    fun bind_int64 = sqlite3_bind_int64(statement : Statement, index : Int32, value : Int64) : Int32
    fun bind_double = sqlite3_bind_double(statement : Statement, index : Int32, value : Float64) : Int32
    fun bind_text = sqlite3_bind_text(statement : Statement, index : Int32, value : UInt8*, bytes : Int32, destructor : Void*) : Int32
    fun bind_blob = sqlite3_bind_blob(statement : Statement, index : Int32, value : Void*, bytes : Int32, destructor : Void*) : Int32
  end

  alias C = SQLiteSQLOracle::LibOracle

  OPEN_READWRITE_CREATE = 0x02 | 0x04
  ROW                   = 100
  DONE                  = 101
  # SQLITE_TRANSIENT: C copies bound text and blobs.
  TRANSIENT = Pointer(Void).new(-1_i64.to_u64!)

  # The outcome of one query: its column names and rows, or C's error.
  record Outcome, list_of_column_names : Array(String), list_of_rows : Array(Array(Value)), error : String?,
    list_of_ties : Array(Bool)

  class Connection
    getter handle : LibQueryOracle::Database

    def initialize(path : String)
      status = C.open_v2(path, out handle, OPEN_READWRITE_CREATE, nil)
      raise "sqlite3_open_v2 #{path}: #{status}" unless status == 0
      @handle = handle
    end

    def close : Nil
      C.close_v2(@handle)
    end

    # Runs SQL that returns no rows; returns C's error message or nil.
    def exec(sql : String) : String?
      status = C.exec(@handle, sql, nil, nil, nil)
      status == 0 ? nil : String.new(C.errmsg(@handle))
    end

    # The parameter count C reports for *sql*, or nil when C rejects it.
    def parameter_count(sql : String) : Int32?
      status = C.prepare_v2(@handle, sql, sql.bytesize, out statement, nil)
      if status != 0
        C.finalize(statement) unless statement.null?
        return nil
      end
      count = LibQueryOracle.bind_parameter_count(statement)
      C.finalize(statement)
      count
    end

    def query(sql : String, parameters : Array(Value) = [] of Value, row_limit : Int32 = 100_000) : Outcome
      status = C.prepare_v2(@handle, sql, sql.bytesize, out statement, nil)
      if status != 0 || statement.null?
        message = String.new(C.errmsg(@handle))
        C.finalize(statement) unless statement.null?
        return Outcome.new([] of String, [] of Array(Value), message, [] of Bool)
      end
      begin
        parameters.each_with_index { |value, index| bind(statement, index + 1, value) }
        columns = C.column_count(statement)
        names = (0...columns).map { |column| String.new(LibQueryOracle.column_name(statement, column)) }
        rows = [] of Array(Value)
        loop do
          result = C.step(statement)
          break if result == DONE
          unless result == ROW
            return Outcome.new(names, rows, String.new(C.errmsg(@handle)), [] of Bool)
          end
          rows << (0...columns).map { |column| read(statement, column) }
          break if rows.size >= row_limit
        end
        Outcome.new(names, rows, nil, [] of Bool)
      ensure
        C.finalize(statement)
      end
    end

    private def bind(statement : LibQueryOracle::Statement, index : Int32, value : Value) : Nil
      case value
      when Nil     then LibQueryOracle.bind_null(statement, index)
      when Int64   then LibQueryOracle.bind_int64(statement, index, value)
      when Float64 then LibQueryOracle.bind_double(statement, index, value)
      when String  then LibQueryOracle.bind_text(statement, index, value, value.bytesize, TRANSIENT)
      when Bytes   then LibQueryOracle.bind_blob(statement, index, value.to_unsafe.as(Void*), value.size, TRANSIENT)
      end
    end

    private def read(statement : LibQueryOracle::Statement, column : Int32) : Value
      case LibQueryOracle.column_type(statement, column)
      when 1 then LibQueryOracle.column_int64(statement, column)
      when 2 then LibQueryOracle.column_double(statement, column)
      when 3
        size = LibQueryOracle.column_bytes(statement, column)
        String.new(C.column_text(statement, column), size)
      when 4
        size = LibQueryOracle.column_bytes(statement, column)
        pointer = LibQueryOracle.column_blob(statement, column).as(UInt8*)
        size == 0 ? Bytes.empty : Bytes.new(pointer, size).dup
      else
        nil
      end
    end
  end

  # The same query on Grant's engine, through a session on *path*.
  def self.engine_query(session : Grant::SQLiteEngine::Query::Session, sql : String,
                        parameters : Array(Value) = [] of Value, row_limit : Int32 = 100_000) : Outcome
    query = session.prepare(sql)
    parameters.each_with_index do |value, index|
      query.bind(index + 1, value) if index < query.parameter_count
    end
    rows = [] of Array(Value)
    ties = [] of Bool
    while query.step
      rows << query.row
      ties << (query.tied_with_previous? || false)
      break if rows.size >= row_limit
    end
    Outcome.new(query.list_of_column_names, rows, nil, ties)
  rescue error : Grant::SQLiteEngine::SQLError
    Outcome.new([] of String, [] of Array(Value), error.message, [] of Bool)
  end

  # A value as a comparable token: the storage class and, for reals, the
  # IEEE 754 bits.
  def self.token(value : Value) : String
    case value
    when Nil     then "NULL"
    when Int64   then "i:#{value}"
    when Float64 then "r:#{value.unsafe_as(UInt64).to_s(16)}"
    when String  then "t:#{value.inspect}"
    else              "b:#{value.hexstring}"
    end
  end

  # A value as it compares under NOCASE and RTRIM with numbers compared by
  # value: what stays the same whichever of several equal values a GROUP
  # BY, DISTINCT or compound shows.
  def self.folded_token(value : Value) : String
    case value
    when Nil     then "NULL"
    when Int64   then "n:#{value.to_f64 == 0.0 ? 0.0 : value.to_f64}"
    when Float64 then "n:#{value == 0.0 ? 0.0 : value}"
    when String  then "t:#{value.rstrip(' ').downcase.inspect}"
    else              "b:#{value.hexstring}"
    end
  end

  def self.row_token(row : Array(Value)) : String
    row.map { |value| token(value) }.join('|')
  end

  # The first difference between C's outcome and the engine's, or nil.
  # With *ordered*, rows must come in the same order, except that rows the
  # engine reports as tied may come in any order among themselves; without
  # it the rows compare as multisets.
  def self.difference(expected : Outcome, actual : Outcome, ordered : Bool, folded : Bool = false) : String?
    if expected.error || actual.error
      return nil if expected.error == actual.error
      return "error: C #{expected.error.inspect}, engine #{actual.error.inspect}"
    end
    if expected.list_of_column_names != actual.list_of_column_names
      return "column names: C #{expected.list_of_column_names}, engine #{actual.list_of_column_names}"
    end
    if expected.list_of_rows.size != actual.list_of_rows.size
      return "row count: C #{expected.list_of_rows.size}, engine #{actual.list_of_rows.size}"
    end
    expected_tokens = expected.list_of_rows.map { |row| folded ? row.map { |value| folded_token(value) }.join('|') : row_token(row) }
    actual_tokens = actual.list_of_rows.map { |row| folded ? row.map { |value| folded_token(value) }.join('|') : row_token(row) }
    unless ordered
      return nil if expected_tokens.sort == actual_tokens.sort
      return "rows differ (unordered): C #{(expected_tokens - actual_tokens).first?}, engine #{(actual_tokens - expected_tokens).first?}"
    end
    start = 0
    while start < actual_tokens.size
      finish = start + 1
      while finish < actual_tokens.size && actual.list_of_ties[finish]?
        finish += 1
      end
      left = expected_tokens[start...finish]
      right = actual_tokens[start...finish]
      unless left.sort == right.sort
        position = (0...left.size).find { |index| left[index] != right[index] } || 0
        return "rows differ at #{start + position}: C #{left[position]}, engine #{right[position]}"
      end
      start = finish
    end
    nil
  end
end
