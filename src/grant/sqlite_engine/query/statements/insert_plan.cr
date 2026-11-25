module Grant::SQLiteEngine::Query
  # INSERT and REPLACE (lang_insert.html): rows from VALUES, a SELECT or
  # DEFAULT VALUES, mapped to the table's columns, written with C's
  # constraint order, conflict resolution, upsert and RETURNING.
  class InsertPlan < StatementPlan
    # Which columns the statement gives a value, for the row being built.
    @assigned = [] of Bool
    @table : WriteTable
    @target_name : String
    # For each source column, the table position it fills (-1: the rowid).
    @list_of_source_positions : Array(Int32)
    @source : CompiledSelect?
    @override : ConflictAction
    @upsert : UpsertPlan?
    @returning : RowProgram?
    @returning_pseudo : PseudoTable?

    @trigger_programs : TriggerProgramCache?

    # *override* is the conflict policy of the statement whose trigger runs
    # this one: when it gave one, it replaces this statement's own.
    def initialize(@session : Session, @statement : SQL::Insert, override : ConflictAction = ConflictAction::Default)
      table_name = @statement.table.name.value
      schema = @statement.table.schema
      if schema && !@session.schema?(schema.value)
        raise SQLError.new("no such table: #{schema.value}.#{table_name}")
      end
      schema_text = schema.try(&.value)
      if @session.view(table_name)
        raise SQLError.new("cannot modify #{table_name} because it is a view")
      end
      if Session::MASTER_NAMES.includes?(table_name.downcase) || Session::TEMP_MASTER_NAMES.includes?(table_name.downcase)
        raise SQLError.new("table #{table_name} may not be modified")
      end
      @table = @session.write_table(table_name, schema_text) || raise SQLError.new("no such table: #{schema_text ? "#{schema_text}." : ""}#{table_name}")
      info = @table.table_info
      @target_name = @statement.table.alias_name.try(&.value) || info.name
      @override = @statement.verb.replace? ? ConflictAction::Replace : ConflictAction.from(@statement.conflict)
      @override = override unless override.default?
      generated = @table.list_of_columns.select(&.generated?).map(&.position).to_set
      positions = if columns = @statement.columns
                    columns.map do |column|
                      position = info.column_index(column.value)
                      if position.nil?
                        if !RowidName.rowid?(info, column.value) || info.without_rowid?
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
      if (upsert = @upsert) && (scope = @session.trigger_scope)
        upsert.list_of_clauses.each(&.trigger_scope=(scope))
      end
      if returning = @statement.returning
        pseudo = PseudoTable.new(@target_name, info)
        @returning_pseudo = pseudo
        program = RowProgram.new(@session, returning, [pseudo])
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
      # A loop among the generated columns fails the statement when it is
      # prepared, whatever rows it would write.
      @table.list_of_generated_in_order(@session)
      @trigger_programs = TriggerProgramCache.for_plan(@session, @table.list_of_triggers(@session), @table.trigger_target,
        SQL::TriggerEvent::Insert, nil, @override)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = @returning ? [] of Array(Value) : NO_ROWS
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        # A single-row INSERT (no SELECT, one VALUES row, no RETURNING
        # trigger, no REPLACE that deletes rows) raises an immediate foreign
        # key at once (fkLookupParent's !isMultiWrite case).
        multi, journal, _ = journal_choices(@session.foreign_keys?) do
          if @table.has_triggers_for?(@session, SQL::TriggerEvent::Insert)
            # A trigger makes the INSERT a multi-write whose program may abort.
            {true, true, false}
          else
            several = StatementJournal.for_insert(@session, @table, @statement, @override, @list_of_source_positions,
              !(@source.nil? || single_values_row?))
            {several[0], several[1], false}
          end
        end
        run.single_row = !multi
        run.statement_journal = journal
        run.trigger_programs = @trigger_programs
        write_returning_rows(run, list_of_parameters, returned)
      end
      returned
    end

    def write_rows(run : WriteRun, list_of_parameters : Array(Value)) : Nil
      write_returning_rows(run, list_of_parameters, NO_ROWS)
    end

    private def write_returning_rows(run : WriteRun, list_of_parameters : Array(Value), returned : Array(Array(Value))) : Nil
      run.open_autoincrement(@table)
      each_source_row(list_of_parameters) do |values|
        row = Array(Value).new(@table.list_of_columns.size, nil)
        # Refilled for each row: it is read only before the row is written.
        assigned = @assigned
        assigned.clear
        row.size.times { assigned << false }
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
        result, rowid, stored = begin
          run.insert_row(@table, row, explicit_rowid, @override, @upsert)
        rescue TriggerIgnore
          next
        end
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
      first, second, rows = Frame.reuse(@frame_keeper, compiled.slot_count, compiled.aggregate_count, list_of_parameters, @session) do |frame|
        read_source_rows(compiled.producer, frame)
      end
      return unless first
      unless second && rows
        # One row (a VALUES row): read in full already, no list needed.
        yield first
        return
      end
      rows.each { |each_row| yield each_row }
    end

    # The frame the source rows are read in, kept for the next run.
    @frame_keeper = FrameKeeper.new

    # Every source row: the first, the second and, when there is a second,
    # the list of them all.
    private def read_source_rows(producer : Producer, frame : Frame) : {Array(Value)?, Array(Value)?, Array(Array(Value))?}
      producer.open(frame)
      first = producer.next_row(frame)
      return {nil, nil, nil} unless first
      second = producer.next_row(frame)
      return {first, nil, nil} unless second
      rows = [first, second]
      while row = producer.next_row(frame)
        rows << row
      end
      {first, second, rows}
    end
  end
end
