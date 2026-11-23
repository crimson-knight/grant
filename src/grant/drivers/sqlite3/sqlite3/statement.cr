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

  # :nodoc:
  #
  # The compiled statement in the connection's engine.
  getter engine_statement : Engine::PreparedStatement

  def initialize(connection, command)
    super(connection, command)
    sqlite3_connection.capture_prepared_statement(command)
    prepare_code, @engine_statement = sqlite3_connection.engine_database.prepare(command)
    check prepare_code
  end

  protected def perform_query(args : Enumerable) : DB::ResultSet
    clear_arg_refs
    @engine_statement.reset
    @last_step_failed = false
    args.each_with_index(1) do |arg, index|
      bind_arg(index, arg)
    end
    ResultSet.new(self)
  end

  protected def perform_exec(args : Enumerable) : DB::ExecResult
    clear_arg_refs
    @engine_statement.reset
    @last_step_failed = false
    args.each_with_index(1) do |arg, index|
      bind_arg(index, arg)
    end

    # exec
    step_code = Engine::ROW_CODE
    while step_code == Engine::ROW_CODE
      step_code = @engine_statement.step
    end
    unless step_code == Engine::DONE_CODE
      record_step_failure
      raise Exception.new(sqlite3_connection)
    end

    rows_affected = sqlite3_connection.engine_database.changes
    last_id = sqlite3_connection.engine_database.last_insert_rowid

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
    finalize_code = @engine_statement.finalize_statement
    return if finalize_code == 0 || @last_step_failed
    # Finalize freed the statement whatever it returned, so it is marked
    # closed before the error is raised; DB::Disposable would otherwise
    # report it open and a later call could reach the freed pointer.
    @closed = true
    raise Exception.new(sqlite3_connection)
  end

  private def bind_arg(index, value : Nil)
    check @engine_statement.bind_null(index)
  end

  private def bind_arg(index, value : Bool)
    check @engine_statement.bind_int64(index, value ? 1_i64 : 0_i64)
  end

  private def bind_arg(index, value : Int8 | Int16 | Int32 | Int64 | UInt8 | UInt16 | UInt32)
    check @engine_statement.bind_int64(index, value.to_i64)
  end

  private def bind_arg(index, value : Float32 | Float64)
    check @engine_statement.bind_double(index, value.to_f64)
  end

  private def bind_arg(index, value : String)
    track_arg_ref(value)
    check @engine_statement.bind_text(index, value)
  end

  private def bind_arg(index, value : Bytes)
    track_arg_ref(value)
    check @engine_statement.bind_blob(index, value)
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
end
