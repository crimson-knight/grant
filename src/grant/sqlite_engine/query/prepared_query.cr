module Grant::SQLiteEngine::Query
  # A compiled SELECT with its parameters, run a row at a time like a
  # `sqlite3_stmt`: bind, step until it returns false, read each row,
  # reset to run again.
  class PreparedQuery
    getter list_of_column_names : Array(String)
    getter parameter_count : Int32
    # The text of each named parameter (`:name`, `@name`, `$name`, `?NNN`)
    # and its number.
    getter parameter_numbers : Hash(String, Int32)
    # The current row. It holds until the next `step` or `reset` (as C's
    # column values do); copy it to keep it.
    getter row : Array(Value) = NO_ROW

    @compiled : CompiledSelect
    @parameters : Array(Value)

    # False for a statement that only moves the transaction state (BEGIN
    # DEFERRED, COMMIT, ROLLBACK of the whole transaction, SAVEPOINT,
    # RELEASE): like C's OP_AutoCommit and OP_Savepoint, it reads no page,
    # so running it takes no read lock of its own. False too for a PRAGMA
    # that reads no page (`PragmaFileAccess`).
    getter? reads_database = true
    @frame : Frame? = nil
    @done = false
    # Whether the statement runs through a plan (anything but a SELECT).
    @runs_a_plan = false
    @plan_frame : Frame? = nil
    # The row of a query that has none (or none yet), shared by every
    # statement: nothing adds to it.
    NO_ROW = [] of Value

    # A statement with no parameters has no parameter names; every such
    # statement shares this table, which nothing changes.
    NO_PARAMETER_NAMES = {} of String => Int32
    # Their bindings: none, so binding fails the range check and nothing
    # changes the list.
    NO_PARAMETERS = [] of Value

    # The name of a SAVEPOINT or RELEASE read without the parser; its plan
    # is shared, so the name travels in the frame.
    @savepoint_name : String? = nil

    def initialize(@session : Session, sql : String)
      # SAVEPOINT and RELEASE of a bare name skip the parser: an ORM sends a
      # new name around every row it writes in a transaction.
      # Statements of one shape share a compiled plan that takes the name
      # when it runs.
      if statement = SQL::SavepointText.parse(sql)
        @savepoint_name = SQL::SavepointText.name_of(statement)
        @parameter_count = 0
        @parameter_numbers = NO_PARAMETER_NAMES
        @reads_database = false
        @compiled = @session.savepoint_shape(statement)
        @list_of_column_names = @compiled.list_of_column_names
        @parameters = NO_PARAMETERS
        @runs_a_plan = true
        return
      end
      prepared = begin
        SQL::Parser.parse_prepared(sql)
      rescue error : SQL::ParseError
        raise SQLError.new(error.message || "syntax error")
      end
      raise SQLError.new("not an error: empty statement") unless prepared
      statement = prepared.statement
      select_statement = statement.as?(SQL::SelectStatement)
      unless select_statement
        # Every other statement runs through its plan (G4b), when the
        # query is first stepped.
        @parameter_count = prepared.parameter_count
        @parameter_numbers = prepared.parameter_numbers
        if @parameter_count > SQL::Limits::MAX_VARIABLE_NUMBER
          raise SQLError.new("too many SQL variables")
        end
        @reads_database = !PreparedQuery.transaction_control?(statement) && PragmaFileAccess.run_reads_file?(statement)
        plan = StatementCompiler.compile(@session, statement, prepared.text)
        producer = PlanProducer.new(@session, plan, statement, prepared.text)
        @compiled = CompiledSelect.new(producer, plan.list_of_column_names, 0, 0, false)
        @list_of_column_names = @compiled.list_of_column_names
        @parameters = Array(Value).new(@parameter_count, nil)
        @runs_a_plan = true
        return
      end
      @parameter_count, @parameter_numbers = ParameterScan.scan(select_statement)
      if @parameter_count > SQL::Limits::MAX_VARIABLE_NUMBER
        raise SQLError.new("too many SQL variables")
      end
      @compiled = Compiler.new(@session).compile(select_statement)
      # Callers read `row` before the next step, so the producer may reuse
      # one array for every row.
      @compiled.producer.lend_rows
      @list_of_column_names = @compiled.list_of_column_names
      @parameters = Array(Value).new(@parameter_count, nil)
    end

    def self.transaction_control?(statement : SQL::Statement) : Bool
      return !(statement.mode.immediate? || statement.mode.exclusive?) if statement.is_a?(SQL::Begin)
      return statement.savepoint.nil? if statement.is_a?(SQL::Rollback)
      statement.is_a?(SQL::Commit) || statement.is_a?(SQL::Savepoint) || statement.is_a?(SQL::Release)
    end

    def self.statement_kind(statement : SQL::Statement) : String
      statement.class.name.split("::").last.upcase
    end

    def column_count : Int32
      @list_of_column_names.size
    end

    # Binds parameter *index* (from 1). Raises SQLITE_RANGE's error past the
    # parameter count.
    def bind(index : Int32, value : Value) : Nil
      unless index >= 1 && index <= @parameter_count
        raise SQLError.new("column index out of range", SQLError::RANGE)
      end
      @parameters[index - 1] = value
    end

    def clear_bindings : Nil
      @parameters.fill(nil)
    end

    # Moves to the next row: true with `row` holding it, false when the
    # query is finished.
    def step : Bool
      return false if @done
      outer_clock = @session.statement_clock
      @session.statement_clock = @statement_clock
      begin
        advance
      ensure
        @session.statement_clock = outer_clock
      end
    end

    @statement_clock = StatementClock.new

    private def advance : Bool
      frame = @frame ||= begin
        @session.json_cache.clear
        new_frame = frame_for_run
        @compiled.producer.open(new_frame)
        new_frame
      end
      next_row = @compiled.producer.next_row(frame)
      unless next_row
        @done = true
        @row = NO_ROW
        return false
      end
      @row = next_row
      true
    end

    # Whether the row just read sorts equal to the one before it under the
    # top-level ORDER BY (for comparing results whose tie order SQL leaves
    # open); nil without an ORDER BY.
    def tied_with_previous? : Bool?
      return unless @compiled.ordered?
      @compiled.producer.tied_with_previous?
    end

    def reset : Nil
      @statement_clock.reset
      @frame = nil
      @done = false
      @row = NO_ROW
    end

    # A statement run through its plan reads only the parameters from its
    # frame, so it keeps one frame and copies the bindings into it. A
    # SELECT keeps one too, started for each run: what uncorrelated
    # subqueries remember holds for one run of the frame.
    private def frame_for_run : Frame
      if @runs_a_plan
        # Without parameters the frame holds nothing: one serves every such
        # statement of the session.
        if name = @savepoint_name
          return @session.savepoint_frame(name)
        end
        return @session.frame_without_parameters if @parameter_count == 0
        frame = @plan_frame ||= Frame.new(0, 0, Array(Value).new(@parameter_count, nil), @session)
        ValueBuffer.refill(frame.list_of_parameters, @parameters)
        return frame
      end
      # One frame serves every run, started afresh each time (its run
      # number tells the caches apart), with its own copy of the bindings.
      if frame = @select_frame
        list_of_parameters = frame.list_of_parameters
        ValueBuffer.refill(list_of_parameters, @parameters)
        frame.start_run(list_of_parameters)
        return frame
      end
      @select_frame = Frame.new(@compiled.slot_count, @compiled.aggregate_count, @parameters.dup, @session)
    end

    @select_frame : Frame? = nil

    # Every row the query returns.
    def all_rows : Array(Array(Value))
      rows = [] of Array(Value)
      while step
        rows << @row.dup
      end
      rows
    end
  end

  # Finds the parameters of a statement: the highest number SQLite
  # assigned, and the numbers of named parameters.
  module ParameterScan
    def self.scan(statement : SQL::SelectStatement) : {Int32, Hash(String, Int32)}
      names = {} of String => Int32
      highest = 0
      visit_select(statement) do |parameter|
        highest = Math.max(highest, parameter.number)
        text = parameter.text
        names[text] = parameter.number unless text == "?"
      end
      {highest, names}
    end

    private def self.visit_select(statement : SQL::SelectStatement, &block : SQL::Parameter ->) : Nil
      if with_clause = statement.with_clause
        with_clause.tables.each { |table| visit_select(table.query, &block) }
      end
      statement.cores.each do |core|
        case core
        when SQL::SelectClause
          core.columns.each do |column|
            visit_expression(column.expression, &block) if column.is_a?(SQL::ExpressionColumn)
          end
          if from = core.from
            visit_from(from, &block)
          end
          core.where.try { |expression| visit_expression(expression, &block) }
          core.group_by.each { |expression| visit_expression(expression, &block) }
          core.having.try { |expression| visit_expression(expression, &block) }
        when SQL::ValuesClause
          core.rows.each(&.each { |expression| visit_expression(expression, &block) })
        end
      end
      statement.order_by.each { |term| visit_expression(term.expression, &block) }
      if limit = statement.limit
        visit_expression(limit.count, &block)
        limit.offset.try { |expression| visit_expression(expression, &block) }
      end
    end

    private def self.visit_from(from : SQL::From, &block : SQL::Parameter ->) : Nil
      from.items.each do |item|
        case source = item.source
        when SQL::TableFunction  then source.arguments.each { |argument| visit_expression(argument, &block) }
        when SQL::SubquerySource then visit_select(source.query, &block)
        when SQL::NestedJoin     then visit_from(source.from, &block)
        end
        item.on.try { |expression| visit_expression(expression, &block) }
      end
    end

    private def self.visit_expression(expression : SQL::Expression, &block : SQL::Parameter ->) : Nil
      case expression
      when SQL::Parameter      then block.call(expression)
      when SQL::Exists         then visit_select(expression.query, &block)
      when SQL::ScalarSubquery then visit_select(expression.query, &block)
      when SQL::InSelect
        visit_expression(expression.operand, &block)
        visit_select(expression.query, &block)
      when SQL::InTable
        visit_expression(expression.operand, &block)
        expression.arguments.try(&.each { |argument| visit_expression(argument, &block) })
      else
        Walker.each_child(expression) { |child| visit_expression(child, &block) }
      end
    end

    # The children an expression has outside subqueries.
    module Walker
      extend ExpressionCompiler

      def self.children(expression : SQL::Expression) : Array(SQL::Expression)
        children_of(expression)
      end

      def self.each_child(expression : SQL::Expression, & : SQL::Expression ->) : Nil
        each_child_of(expression) { |child| yield child }
      end
    end
  end
end
