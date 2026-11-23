module Grant::SQLiteEngine::Query
  # INSERT and REPLACE (lang_insert.html): rows from VALUES, a SELECT or
  # DEFAULT VALUES, mapped to the table's columns, written with C's
  # constraint order, conflict resolution, upsert and RETURNING.
  class InsertPlan < StatementPlan
    @table : WriteTable
    @target_name : String
    # For each source column, the table position it fills (-1: the rowid).
    @list_of_source_positions : Array(Int32)
    @source : CompiledSelect?
    @override : ConflictAction
    @upsert : UpsertPlan?
    @returning : RowProgram?
    @returning_pseudo : PseudoTable?

    def initialize(@session : Session, @statement : SQL::Insert)
      table_name = @statement.table.name.value
      if schema = @statement.table.schema
        unless schema.same?("main")
          raise SQLError.new(schema.same?("temp") ? "no such table: #{schema.value}.#{table_name}" : "unknown database #{schema.value}")
        end
      end
      if @session.view(table_name)
        raise SQLError.new("cannot modify #{table_name} because it is a view")
      end
      if Session::MASTER_NAMES.includes?(table_name.downcase)
        raise SQLError.new("table #{table_name} may not be modified")
      end
      @table = @session.write_table(table_name) || raise SQLError.new("no such table: #{table_name}")
      info = @table.table_info
      @target_name = @statement.table.alias_name.try(&.value) || info.name
      @override = @statement.verb.replace? ? ConflictAction::Replace : ConflictAction.from(@statement.conflict)
      generated = @table.list_of_columns.select(&.generated?).map(&.position).to_set
      positions = if columns = @statement.columns
                    columns.map do |column|
                      position = info.column_index(column.value)
                      if position.nil?
                        unless RowidName.rowid?(info, column.value) && !info.without_rowid?
                          raise SQLError.new("table #{info.name} has no column named #{column.value}")
                        end
                        position = info.rowid_alias || -1
                      end
                      if generated.includes?(position)
                        raise SQLError.new(%(cannot INSERT into generated column "#{column.value}"))
                      end
                      position
                    end
                  else
                    (0...info.list_of_column_names.size).reject { |position| generated.includes?(position) }
                  end
      @list_of_source_positions = @statement.source ? positions : [] of Int32
      if source = @statement.source
        query = source
        if with_clause = @statement.with_clause
          query = SQL::SelectStatement.new(with_clause, source.cores, source.operators, source.order_by, source.limit)
        end
        compiled = Compiler.new(@session).compile(query)
        width = compiled.list_of_column_names.size
        if @statement.columns.nil? && width != positions.size
          raise SQLError.new("table #{info.name} has #{positions.size} columns but #{width} values were supplied")
        end
        if @statement.columns && width != positions.size
          raise SQLError.new("#{width} values for #{positions.size} columns")
        end
        @source = compiled
      end
      @upsert = UpsertPlan.compile(@table, @statement.upserts, @target_name)
      if returning = @statement.returning
        pseudo = PseudoTable.new(@target_name, info)
        @returning_pseudo = pseudo
        program = RowProgram.new(@session, returning, [pseudo])
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = [] of Array(Value)
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        # A single-row INSERT (no SELECT, one VALUES row, no RETURNING
        # trigger, no REPLACE that deletes rows) raises an immediate foreign
        # key at once (fkLookupParent's !isMultiWrite case).
        multi, journal = StatementJournal.for_insert(@session, @table, @statement, @override, @list_of_source_positions,
          !(@source.nil? || single_values_row?))
        run.single_row = !multi
        run.statement_journal = journal
        run.open_autoincrement(@table)
        each_source_row(list_of_parameters) do |values|
          row = Array(Value).new(@table.list_of_columns.size, nil)
          assigned = Array(Bool).new(row.size, false)
          explicit_rowid = nil.as(Value)
          @list_of_source_positions.each_with_index do |position, index|
            if position < 0
              explicit_rowid = values[index]
            else
              row[position] = values[index]
              assigned[position] = true
            end
          end
          @table.list_of_columns.each do |column|
            next if assigned[column.position] || column.generated?
            next if column.position == @table.rowid_alias
            row[column.position] = run.default_value(@table, column)
          end
          result, rowid, stored = run.insert_row(@table, row, explicit_rowid, @override, @upsert)
          next if result.ignored?
          if program = @returning
            pseudo = @returning_pseudo || raise Error.new("RETURNING without its row")
            pseudo.row = stored
            pseudo.rowid = rowid
            if returned_row = program.evaluate(list_of_parameters)
              returned << returned_row
            end
          end
        end
      end
      returned
    end

    # A one-row VALUES without a compound: C inserts it without a
    # statement journal (no isMultiWrite).
    private def single_values_row? : Bool
      source = @statement.source
      return false unless source
      source.cores.size == 1 && (core = source.cores[0]).is_a?(SQL::ValuesClause) && core.rows.size == 1 &&
        @statement.with_clause.nil? && source.with_clause.nil?
    end

    # The source rows, read in full before the first write so a SELECT
    # from the table itself does not see its own inserts.
    private def each_source_row(list_of_parameters : Array(Value), & : Array(Value) ->) : Nil
      compiled = @source
      unless compiled
        yield [] of Value
        return
      end
      frame = Frame.new(compiled.slot_count, compiled.aggregate_count, list_of_parameters, @session)
      producer = compiled.producer
      producer.open(frame)
      rows = [] of Array(Value)
      while row = producer.next_row(frame)
        rows << row
      end
      rows.each { |row| yield row }
    end
  end
end
