class Grant::PG::Statement < ::DB::Statement
  # The server's name for this statement, or `nil` for an unnamed statement.
  @statement_name : String?
  # True once the server has acknowledged parsing this statement.
  @is_parsed_on_server = false
  # True when a name that may still exist on the server must go before the
  # next parse under that same name.
  @must_close_before_parsing = false

  def initialize(connection, command : String, @statement_name : String? = nil)
    super(connection, command)
  end

  protected def conn
    connection.as(Connection).connection
  end

  protected def perform_query(args : Enumerable) : ResultSet
    params = args.map { |arg| PQ::Param.encode(arg) }
    run_on_server(params, may_retry: true)
  rescue e : IO::Error
    raise DB::ConnectionLost.new(connection, cause: e)
  end

  # Sends the statement and reads up to the point where rows begin. A named
  # statement the server already parsed can still be rejected at Bind when its
  # server-side copy no longer matches: SQLSTATE 0A000 ("cached plan must not
  # change result type") after a column changed type, 26000 after `DEALLOCATE
  # ALL` or a pooler reset, and the type errors a stale parameter type raises
  # on writes. Rejection at Bind means nothing executed, so a retry cannot apply
  # a write twice: outside a transaction the statement re-parses and retries
  # once. Inside a transaction the failure already aborted it, so the error
  # reaches the caller and the statement re-parses on its next use.
  private def run_on_server(params, may_retry : Bool) : ResultSet
    conn = self.conn
    statement_name = @statement_name
    must_parse = statement_name.nil? || !@is_parsed_on_server

    count_of_closes = conn.send_close_messages_for_released_statements
    if statement_name && @must_close_before_parsing
      conn.send_close_statement_message(statement_name)
      count_of_closes += 1
    end
    conn.send_parse_message(command, statement_name || "") if must_parse
    conn.send_bind_message(params, statement_name: statement_name || "")
    conn.send_describe_portal_message
    conn.send_execute_message
    conn.send_sync_message

    count_of_closes.times { conn.expect_frame PQ::Frame::CloseComplete }
    if must_parse
      conn.expect_frame PQ::Frame::ParseComplete
      # Set here, not after Bind: a Bind error leaves the name on the server,
      # and parsing it again would fail with "already exists".
      @is_parsed_on_server = !statement_name.nil?
      @must_close_before_parsing = false
    end
    begin
      conn.expect_frame PQ::Frame::BindComplete
    rescue error : PQ::PQError
      raise error if statement_name.nil? || must_parse

      @is_parsed_on_server = false
      @must_close_before_parsing = true
      raise error if !may_retry || conn.in_transaction?

      return run_on_server(params, may_retry: false)
    end
    frame = conn.read
    case frame
    when PQ::Frame::RowDescription
      fields = frame.fields
    when PQ::Frame::NoData
      fields = nil
    else
      raise "expected RowDescription or NoData, got #{frame}"
    end
    ResultSet.new(self, fields)
  end

  protected def perform_exec(args : Enumerable) : ::DB::ExecResult
    result = perform_query(args)
    result.each { }
    ::DB::ExecResult.new(
      rows_affected: result.rows_affected,
      last_insert_id: 0_i64 # postgres doesn't support this
    )
  rescue e : IO::Error
    raise DB::ConnectionLost.new(connection, cause: e)
  end

  protected def do_close
    super

    statement_name = @statement_name
    return unless statement_name
    return unless @is_parsed_on_server || @must_close_before_parsing

    conn.release_server_statement_later(statement_name)
  end
end
