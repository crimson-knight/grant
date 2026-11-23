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
    getter row = [] of Value

    @compiled : CompiledSelect
    @parameters : Array(Value)
    @frame : Frame? = nil
    @done = false

    def initialize(@session : Session, sql : String)
      statement = begin
        SQL::Parser.parse(sql)
      rescue error : SQL::ParseError
        raise SQLError.new(error.message || "syntax error")
      end
      raise SQLError.new("not an error: empty statement") unless statement
      select_statement = statement.as?(SQL::SelectStatement)
      unless select_statement
        raise UnsupportedSQL.new("#{PreparedQuery.statement_kind(statement)} statements arrive with milestone G4b")
      end
      @parameter_count, @parameter_numbers = ParameterScan.scan(select_statement)
      if @parameter_count > SQL::Limits::MAX_VARIABLE_NUMBER
        raise SQLError.new("too many SQL variables")
      end
      @compiled = Compiler.new(@session).compile(select_statement)
      @list_of_column_names = @compiled.list_of_column_names
      @parameters = Array(Value).new(@parameter_count, nil)
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
      frame = @frame ||= begin
        new_frame = Frame.new(@compiled.slot_count, @compiled.aggregate_count, @parameters.dup, @session)
        @compiled.producer.open(new_frame)
        new_frame
      end
      next_row = @compiled.producer.next_row(frame)
      unless next_row
        @done = true
        @row = [] of Value
        return false
      end
      @row = next_row
      true
    end

    # Whether the row just read sorts equal to the one before it under the
    # top-level ORDER BY (for comparing results whose tie order SQL leaves
    # open); nil without an ORDER BY.
    def tied_with_previous? : Bool?
      return nil unless @compiled.ordered?
      @compiled.producer.tied_with_previous?
    end

    def reset : Nil
      @frame = nil
      @done = false
      @row = [] of Value
    end

    # Every row the query returns.
    def all_rows : Array(Array(Value))
      rows = [] of Array(Value)
      while step
        rows << @row
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
        Walker.children(expression).each { |child| visit_expression(child, &block) }
      end
    end

    # The children an expression has outside subqueries.
    module Walker
      extend ExpressionCompiler

      def self.children(expression : SQL::Expression) : Array(SQL::Expression)
        children_of(expression)
      end
    end
  end
end
