class Grant::SQLite3::Statement < DB::Statement
  # Keep references to bound strings and bytes to prevent them from being
  # garbage collected before SQLite executes the statement. It is lazy
  # initialized to help with memory footprint.
  # See https://github.com/crystal-lang/crystal-sqlite3/pull/111 for more
  # context.
  @arg_refs : Array(Pointer(UInt8)) | Nil

  # Set when the statement's most recent step failed and that error was
  # raised to the caller, so a reset or finalize that repeats it is not
  # raised again. Cleared each time the statement runs.
  @last_step_failed = false
  @finalized = false

  # :nodoc:
  def record_step_failure : Nil
    @last_step_failed = true
  end

  # :nodoc:
  def last_step_failed? : Bool
    @last_step_failed
  end

  private def clear_arg_refs
    @arg_refs.try(&.clear)
  end

  private def track_arg_ref(ref)
    arg_refs = @arg_refs ||= [] of Pointer(UInt8)
    arg_refs.push(ref.to_unsafe)
  end

  def initialize(connection, command)
    super(connection, command)
    check LibSQLite3.prepare_v2(sqlite3_connection, command, command.bytesize + 1, out @stmt, nil)
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    clear_arg_refs
    LibSQLite3.reset(self)
    @last_step_failed = false
    args.each_with_index(1) do |arg, index|
      bind_arg(index, arg)
    end
    ResultSet.new(self)
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    clear_arg_refs
    LibSQLite3.reset(self.to_unsafe)
    @last_step_failed = false
    args.each_with_index(1) do |arg, index|
      bind_arg(index, arg)
    end

    # exec
    step = uninitialized LibSQLite3::Code
    loop do
      step = LibSQLite3::Code.new LibSQLite3.step(self)
      break unless step == LibSQLite3::Code::ROW
    end
    unless step == LibSQLite3::Code::DONE
      record_step_failure
      raise Exception.new(sqlite3_connection)
    end

    rows_affected = LibSQLite3.changes(sqlite3_connection).to_i64
    last_id = LibSQLite3.last_insert_rowid(sqlite3_connection)

    DB::ExecResult.new rows_affected, last_id
  end

  # Finalizes the statement once. sqlite3_finalize always frees it and
  # returns the error of the most recent step, which `perform_exec` or
  # `ResultSet#move_next` already raised when that step failed, so that
  # repeat is not raised again. Any other error is new and is raised: a
  # partly read `INSERT ... RETURNING` with a deferred foreign key first
  # reports its failed write here.
  protected def do_close
    super
    clear_arg_refs
    return if @finalized
    @finalized = true
    finalize_code = LibSQLite3.finalize(self)
    unless finalize_code == 0 || @last_step_failed
      raise Exception.new(sqlite3_connection)
    end
  end

  private def bind_arg(index, value : Nil)
    check LibSQLite3.bind_null(self, index)
  end

  private def bind_arg(index, value : Bool)
    check LibSQLite3.bind_int(self, index, value ? 1 : 0)
  end

  private def bind_arg(index, value : UInt8)
    check LibSQLite3.bind_int(self, index, value.to_i)
  end

  private def bind_arg(index, value : UInt16)
    check LibSQLite3.bind_int(self, index, value.to_i)
  end

  private def bind_arg(index, value : UInt32)
    check LibSQLite3.bind_int64(self, index, value.to_i64)
  end

  private def bind_arg(index, value : Int8)
    check LibSQLite3.bind_int(self, index, value.to_i)
  end

  private def bind_arg(index, value : Int16)
    check LibSQLite3.bind_int(self, index, value.to_i)
  end

  private def bind_arg(index, value : Int32)
    check LibSQLite3.bind_int(self, index, value)
  end

  private def bind_arg(index, value : Int64)
    check LibSQLite3.bind_int64(self, index, value)
  end

  private def bind_arg(index, value : Float32)
    check LibSQLite3.bind_double(self, index, value.to_f64)
  end

  private def bind_arg(index, value : Float64)
    check LibSQLite3.bind_double(self, index, value)
  end

  private def bind_arg(index, value : String)
    track_arg_ref(value)
    check LibSQLite3.bind_text(self, index, value, value.bytesize, nil)
  end

  private def bind_arg(index, value : Bytes)
    track_arg_ref(value)
    check LibSQLite3.bind_blob(self, index, value, value.size, nil)
  end

  private def bind_arg(index, value : Time)
    bind_arg(index, value.in(SQLite3::TIME_ZONE).to_s(SQLite3::DATE_FORMAT_SUBSECOND))
  end

  private def bind_arg(index, value)
    raise "#{self.class} does not support #{value.class} params"
  end

  private def check(code)
    raise Exception.new(sqlite3_connection) unless code == 0
  end

  protected def sqlite3_connection
    @connection.as(Connection)
  end

  def to_unsafe
    @stmt
  end
end
