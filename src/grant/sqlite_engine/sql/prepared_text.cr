module Grant::SQLiteEngine::SQL
  # One statement of a SQL text as `sqlite3_prepare_v2` sees it: the syntax
  # tree, the statement's own text (from its first token to the end of its
  # last, before the semicolon), and its parameters: the highest number
  # assigned and the number of each named one.
  record PreparedText, statement : Statement, text : String, parameter_count : Int32,
    parameter_numbers : Hash(String, Int32)

  class Parser
    # Parses the first statement of *sql* with its text and parameters, or
    # returns nil when *sql* holds no statement.
    def self.parse_prepared(sql : String) : PreparedText?
      parser = new(sql)
      parser.next_prepared(sql)
    end

    # Parses every statement of *sql* with its text and parameters.
    def self.parse_each_prepared(sql : String) : Array(PreparedText)
      parser = new(sql)
      list = [] of PreparedText
      while prepared = parser.next_prepared(sql)
        list << prepared
      end
      list
    end

    protected def next_prepared(sql : String) : PreparedText?
      skip_semicolons
      return if kind.end_of_input?
      @parameter_count = 0
      @named_parameters = nil
      @has_with = false
      start = peek.start
      statement = parse_statement
      finish = peek.start
      expect_statement_end
      text = sql.byte_slice(start, finish - start).rstrip
      PreparedText.new(statement, text, @parameter_count, @named_parameters || NO_PARAMETER_NAMES)
    end
  end
end
