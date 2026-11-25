module Grant::SQLiteEngine::Query
  class WriteTable
    # The generated columns in the order their values are computed
    # (sqlite3ComputeGeneratedColumns): pass after pass over the declared
    # order, each pass computing the columns whose expressions read no
    # generated column still waiting.
    def list_of_generated_in_order(session : Session) : Array(ColumnRule)
      if ordered = @list_of_generated_in_order
        return ordered
      end
      waiting = @list_of_columns.select(&.generated?)
      compiler = Compiler.new(session)
      reads = {} of Int32 => Set(Int32)
      waiting.each do |column|
        expression = column.generated_expression || next
        reads[column.position] = compiler.columns_read_by(@table_info, expression)
      end
      ordered = [] of ColumnRule
      until waiting.empty?
        blocked = waiting.map(&.position).to_set
        ready = [] of ColumnRule
        # A column computed earlier in a pass frees the ones after it in
        # the same pass.
        waiting.each do |column|
          next if reads[column.position].any? { |position| blocked.includes?(position) }
          blocked.delete(column.position)
          ready << column
        end
        if ready.empty?
          raise SQLError.new(%(generated column loop on "#{waiting.last.column_name}"))
        end
        ordered.concat(ready)
        waiting -= ready
      end
      @list_of_generated_in_order = ordered
    end

    @list_of_generated_in_order : Array(ColumnRule)? = nil

    # The order NOT NULL is checked in: the ordinary columns, then the
    # generated ones (sqlite3GenerateConstraintChecks leaves them to its
    # second pass).
    getter list_of_columns_in_not_null_order : Array(ColumnRule) do
      has_generated_columns? ? @list_of_columns.reject(&.generated?) + @list_of_columns.select(&.generated?) : @list_of_columns
    end

    def has_virtual_columns? : Bool
      @table_info.has_virtual_columns?
    end
  end

  class WriteRun
    # The values of the generated columns of a new or changed row, STORED
    # and VIRTUAL (a VIRTUAL value stays out of the record; the row's index
    # entries and CHECK constraints read it). The ordinary columns take
    # their affinity first, as sqlite3ComputeGeneratedColumns applies
    # sqlite3TableAffinity before any expression reads them.
    def compute_generated(table : WriteTable, row : Array(Value), rowid : Int64?) : Nil
      return unless table.has_generated_columns?
      definition = table.definition
      list_of_definitions = definition.list_of_columns
      strict = definition.strict?
      table.list_of_columns.each do |column|
        next if column.generated?
        column_definition = list_of_definitions[column.position]
        value = row[column.position]
        row[column.position] = if strict
                                 StoredValue.for_strict_column(column_definition.declared_type, "#{definition.table_name}.#{column_definition.column_name}", value)
                               else
                                 StoredValue.for_affinity(column_definition.affinity, value)
                               end
      end
      if (alias_index = table.rowid_alias) && rowid
        row[alias_index] = rowid
      end
      table.list_of_generated_in_order(@session).each do |column|
        row[column.position] = generated_value(table, column, row, rowid)
      end
    end

    # Fills the VIRTUAL generated columns of *row*, a row read from its
    # record (which leaves them out).
    def fill_virtual_columns(table : WriteTable, row : Array(Value), rowid : Int64?) : Nil
      return unless table.has_virtual_columns?
      table.list_of_generated_in_order(@session).each do |column|
        next if column.generated_stored?
        row[column.position] = generated_value(table, column, row, rowid)
      end
    end

    private def generated_value(table : WriteTable, column : ColumnRule, row : Array(Value), rowid : Int64?) : Value
      expression = column.generated_expression || return row[column.position]
      program = table.generated_programs[column.position] ||= RowProgram.new(@session, RowProgram.columns([expression] of SQL::Expression),
        [PseudoTable.new(table.name, table.table_info)], deterministic_context: "a generated column")
      pseudo = program.list_of_pseudo_tables[0]
      pseudo.row = row
      pseudo.rowid = rowid
      value = program.evaluate(@list_of_parameters).try(&.[0]?)
      VirtualColumnExpr.converted(value, table.definition.list_of_columns[column.position], table.name, table.definition.strict?)
    end
  end
end

module Grant::SQLiteEngine::Query
  # What C reports for the generated columns of a table as its CREATE TABLE
  # is read: an expression that names no column, holds a subquery or calls
  # a function whose value changes; a table of generated columns only; and
  # VIRTUAL columns that read each other in a loop.
  class CheckGeneratedColumnsOfTable
    ROWID_NAMES = %w[rowid oid _rowid_]

    def initialize(@session : Session, @table : TableInfo)
      @list_of_expressions = @table.list_of_generated_expressions
    end

    # For the table *sql* (a CREATE TABLE) is about to create in *database*.
    def self.for_new_table(session : Session, sql : String, database : Database) : CheckGeneratedColumnsOfTable
      definition = TableDefinition.parse(sql)
      entry = SchemaEntry.new("table", definition.table_name, definition.table_name, 0_u32, sql)
      new(session, TableInfo.new(entry, definition, [] of IndexLayout, database))
    end

    # Raises the error CREATE TABLE ends with, if any.
    def perform : Nil
      message = parse_error || loop_error
      raise SQLError.new(message) if message
    end

    # sqlite3EndTable: each generated column's expression is resolved
    # against the table, and sqlite3ErrorMsg keeps the last message.
    def parse_error : String?
      return if @list_of_expressions.none?
      message = nil
      @list_of_expressions.each do |expression|
        next unless expression
        message = expression_error(expression) || message
      end
      return "must have at least one non-generated column" if @list_of_expressions.all?
      message
    end

    # The `SELECT * FROM table` C runs once the table exists: a VIRTUAL
    # column met again while its own expression is being coded is a loop.
    # Coding goes on after the error, and the last message is the one kept.
    def loop_error : String?
      @loop_message = nil
      in_progress = Set(Int32).new
      @list_of_expressions.each_with_index do |expression, position|
        read_virtual_column(position, in_progress) if expression && @table.virtual_column?(position)
      end
      @loop_message
    end

    @loop_message : String? = nil

    private def read_virtual_column(position : Int32, in_progress : Set(Int32)) : Nil
      if in_progress.includes?(position)
        @loop_message = %(generated column loop on "#{@table.list_of_column_names[position]}")
        return
      end
      expression = @list_of_expressions[position] || return
      in_progress << position
      read_columns_of(expression, in_progress)
      in_progress.delete(position)
    end

    private def read_columns_of(expression : SQL::Expression, in_progress : Set(Int32)) : Nil
      if expression.is_a?(SQL::ColumnReference)
        position = @table.column_index(expression.column.value)
        read_virtual_column(position, in_progress) if position && @table.virtual_column?(position)
      end
      compiler.children_of(expression).each { |child| read_columns_of(child, in_progress) }
    end

    private getter compiler : Compiler { Compiler.new(@session) }

    private def expression_error(expression : SQL::Expression) : String?
      refuse_prohibited(expression)
      Compiler.new(@session).columns_read_by(@table, expression)
      nil
    rescue error : SQLError
      message = error.message
      # A loop is found when the table is first read, not when it is parsed.
      return if message.nil? || message.starts_with?("generated column loop")
      message
    end

    # resolveExprStep under NC_GenCol, node before operands.
    private def refuse_prohibited(expression : SQL::Expression) : Nil
      if expression.is_a?(SQL::ScalarSubquery) || expression.is_a?(SQL::Exists) || expression.is_a?(SQL::InSelect)
        raise SQLError.new("subqueries prohibited in generated columns")
      end
      if expression.is_a?(SQL::FunctionCall) && ExpressionWalk::NONDETERMINISTIC.includes?(expression.name.value.downcase)
        raise SQLError.new("non-deterministic functions prohibited in generated columns")
      end
      if expression.is_a?(SQL::ColumnReference) && expression.table.nil?
        name = expression.column.value
        if ROWID_NAMES.includes?(name.downcase) && @table.column_index(name).nil?
          raise SQLError.new("no such column: #{name}")
        end
      end
      compiler.children_of(expression).each { |child| refuse_prohibited(child) }
    end
  end
end
