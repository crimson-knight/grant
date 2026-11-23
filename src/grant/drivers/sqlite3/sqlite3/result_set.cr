class Grant::SQLite3::ResultSet < DB::ResultSet
  @column_index = 0
  @reset_done = false

  # Resets the statement once, then releases it. sqlite3_reset repeats the
  # error of a failed step, which `move_next` already raised, so that code
  # is not raised again. Any other error is new and is raised: resetting a
  # partly read `INSERT ... RETURNING` commits its write and can fail with
  # SQLITE_BUSY, and dropping that code would hide a lost write.
  #
  # The release runs on every close until it succeeds, because returning the
  # connection to its pool can close it, and SQLite can refuse that close;
  # the result set then stays open so a later close retries the release.
  # Once released, it reports closed even when the reset error is raised.
  protected def do_close
    reset_error = nil
    unless @reset_done
      @reset_done = true
      statement = sqlite3_statement
      reset_code = statement.engine_statement.reset
      unless reset_code == 0
        reset_error = Exception.new(statement.sqlite3_connection) unless statement.last_step_failed?
        statement.record_step_failure
      end
    end

    begin
      super
    rescue release_error : Exception
      raise reset_error || release_error
    end

    if reset_error
      @closed = true
      raise reset_error
    end
  end

  # Advances to the next row. Returns `true` if there's a next row,
  # `false` otherwise. Must be called at least once to advance to the first
  # row.
  def move_next : Bool
    @column_index = 0

    case engine_statement.step
    when Engine::ROW_CODE
      true
    when Engine::DONE_CODE
      false
    else
      sqlite3_statement.record_step_failure
      raise Exception.new(sqlite3_statement.sqlite3_connection)
    end
  end

  def read
    col = @column_index
    statement = engine_statement
    value =
      case statement.column_type(col)
      when Type::INTEGER
        statement.column_int64(col)
      when Type::FLOAT
        statement.column_double(col)
      when Type::BLOB
        statement.column_blob(col)
      when Type::TEXT
        statement.column_text(col)
      when Type::NULL
        nil
      else
        raise Exception.new(sqlite3_statement.sqlite3_connection)
      end
    @column_index += 1
    value
  end

  def next_column_index : Int32
    @column_index
  end

  def read(t : UInt8.class) : UInt8
    read(Int64).to_u8
  end

  def read(type : UInt8?.class) : UInt8?
    read(Int64?).try &.to_u8
  end

  def read(t : UInt16.class) : UInt16
    read(Int64).to_u16
  end

  def read(type : UInt16?.class) : UInt16?
    read(Int64?).try &.to_u16
  end

  def read(t : UInt32.class) : UInt32
    read(Int64).to_u32
  end

  def read(type : UInt32?.class) : UInt32?
    read(Int64?).try &.to_u32
  end

  def read(t : Int8.class) : Int8
    read(Int64).to_i8
  end

  def read(type : Int8?.class) : Int8?
    read(Int64?).try &.to_i8
  end

  def read(t : Int16.class) : Int16
    read(Int64).to_i16
  end

  def read(type : Int16?.class) : Int16?
    read(Int64?).try &.to_i16
  end

  def read(t : Int32.class) : Int32
    read(Int64).to_i32
  end

  def read(type : Int32?.class) : Int32?
    read(Int64?).try &.to_i32
  end

  def read(t : Float32.class) : Float32
    read(Float64).to_f32
  end

  def read(type : Float32?.class) : Float32?
    read(Float64?).try &.to_f32
  end

  def read(t : Time.class) : Time
    text = read(String)
    if text.includes? "."
      Time.parse text, SQLite3::DATE_FORMAT_SUBSECOND, location: SQLite3::TIME_ZONE
    else
      Time.parse text, SQLite3::DATE_FORMAT_SECOND, location: SQLite3::TIME_ZONE
    end
  end

  def read(t : Time?.class) : Time?
    read(String?).try { |v|
      if v.includes? "."
        Time.parse v, SQLite3::DATE_FORMAT_SUBSECOND, location: SQLite3::TIME_ZONE
      else
        Time.parse v, SQLite3::DATE_FORMAT_SECOND, location: SQLite3::TIME_ZONE
      end
    }
  end

  def read(t : Bool.class) : Bool
    read(Int64) != 0
  end

  def read(t : Bool?.class) : Bool?
    read(Int64?).try &.!=(0)
  end

  def column_count : Int32
    engine_statement.column_count
  end

  def column_name(index) : String
    engine_statement.column_name(index)
  end

  private def engine_statement : Engine::PreparedStatement
    sqlite3_statement.engine_statement
  end

  protected def sqlite3_statement
    @statement.as(Statement)
  end

  private def moving_column(&)
    res = yield @column_index
    @column_index += 1
    res
  end
end
