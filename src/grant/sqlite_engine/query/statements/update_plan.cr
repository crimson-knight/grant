module Grant::SQLiteEngine::Query
  # The rows an UPDATE or DELETE changes: a SELECT over the target table
  # (and an UPDATE's FROM) whose result columns are the values to compute,
  # run to the end before the first write, with the target row's rowid and
  # values read from its frame slot.
  class TargetRows
    getter list_of_column_names : Array(String)

    @compiled : CompiledSelect
    @slot : Int32

    # The snapshot of a target found by rowid, which nothing reads or changes.
    NO_SNAPSHOT = [] of Value
    # The index the rows are read through (nil: the table, in rowid order).
    getter scan_index_root : UInt32?

    def initialize(@session : Session, table : TableInfo, reference : SQL::QualifiedTable, indexed_by : SQL::Name?,
                   not_indexed : Bool, columns : Array(SQL::ResultColumn), from : SQL::From?, where : SQL::Expression?,
                   with_clause : SQL::WithClause?)
      source = SQL::TableReference.new(reference.schema, reference.name, reference.alias_name, indexed_by, not_indexed)
      items = [SQL::FromItem.new(nil, source, nil, nil)]
      if from
        from.items.each_with_index do |item, index|
          join = index == 0 ? SQL::JoinOperator.new(true, [] of String) : item.join
          items << SQL::FromItem.new(join, item.source, item.on, item.using)
        end
      end
      columns = [SQL::ExpressionColumn.new(SQL::Literal.new(SQL::LiteralKind::Null, "NULL"), nil).as(SQL::ResultColumn)] if columns.empty?
      core = SQL::SelectClause.new(SQL::DistinctMode::None, columns, SQL::From.new(items), where, [] of SQL::Expression,
        nil, [] of SQL::WindowDefinition)
      statement = SQL::SelectStatement.new(with_clause, [core] of SQL::SelectCore, [] of SQL::CompoundOperator,
        [] of SQL::OrderingTerm, nil)
      compiler = Compiler.new(@session)
      compiler.capture_name = reference.name.value
      @compiled = compiler.compile(statement)
      @slot = compiler.captured_slot || raise Error.new("the target table of a write was not compiled")
      @scan_index_root = compiler.captured_index_root
      @list_of_column_names = @compiled.list_of_column_names
      # collect_in copies each row's values out before it asks for the next.
      @compiled.producer.lend_rows
    end

    # Yields every target row once (the first match of an UPDATE ... FROM):
    # its rowid (nil for WITHOUT ROWID), its values and the computed
    # columns. The list is kept for the next run once the block returns,
    # so the block must not keep it; a run inside the block (a trigger that
    # comes back to this statement) collects into a list of its own.
    def collect(list_of_parameters : Array(Value), & : Array({Int64?, Array(Value), Array(Value)}) ->) : Nil
      rows = @spare_rows || [] of {Int64?, Array(Value), Array(Value)}
      @spare_rows = nil
      Frame.reuse(@frame_keeper, @compiled.slot_count, @compiled.aggregate_count, list_of_parameters, @session) do |frame|
        collect_in(frame, rows)
      end
      begin
        yield rows
      ensure
        rows.each do |(_, _, values)|
          break if @list_of_spare_values.size >= SPARE_VALUE_LIMIT
          @list_of_spare_values << values
        end
        rows.clear
        @spare_rows = rows
      end
    end

    @spare_rows : Array({Int64?, Array(Value), Array(Value)})? = nil

    # The value arrays of the last run's rows, refilled by the next run; at
    # most SPARE_VALUE_LIMIT are kept, so a run over many rows does not keep
    # them all.
    @list_of_spare_values = [] of Array(Value)
    SPARE_VALUE_LIMIT = 8

    # A copy of the lent *values*, in an array kept from an earlier run when
    # there is one.
    private def copy_of(values : Array(Value)) : Array(Value)
      copy = @list_of_spare_values.pop? || Array(Value).new(values.size)
      copy.clear.concat(values)
    end

    # The frame collect runs in, kept for the next run.
    @frame_keeper = FrameKeeper.new

    private def collect_in(frame : Frame, rows : Array({Int64?, Array(Value), Array(Value)})) : Nil
      producer = @compiled.producer
      producer.open(frame)
      # The rowids taken so far, built once a second row arrives (most
      # writes change one row).
      seen = nil.as(Set(Int64)?)
      while values = producer.next_row(frame)
        rowid = frame.list_of_rowids[@slot]
        if rowid && !rows.empty?
          taken = seen ||= rows.compact_map(&.[0]).to_set
          next unless taken.add?(rowid)
        end
        frame.complete_row(@slot)
        # A rowid table finds the row again by its rowid; only a WITHOUT
        # ROWID table reads the snapshot (its primary key).
        rows << {rowid, rowid ? NO_SNAPSHOT : frame.list_of_rows[@slot].dup, copy_of(values)}
      end
    end
  end

  # The arrays an UPDATE or DELETE reads each target row into (and an
  # UPDATE builds the new row in), kept by the plan from run to run. A run
  # takes its plan's scratch and gives it back when it ends, so a run that
  # starts inside it (a trigger that comes back to the same plan) reads
  # into a scratch of its own.
  class RowScratch
    getter old_row = [] of Value
    @new_row = [] of Value

    # The new row, starting as a copy of *old*.
    def new_row_from(old : Array(Value)) : Array(Value)
      @new_row.clear.concat(old)
    end
  end

  # Checks shared by UPDATE and DELETE: the target must be a writable table.
  module WritableTarget
    def self.check(session : Session, reference : SQL::QualifiedTable) : WriteTable
      table_name = reference.name.value
      schema = reference.schema
      if schema && !session.schema?(schema.value)
        raise SQLError.new("no such table: #{schema.value}.#{table_name}")
      end
      schema_text = schema.try(&.value)
      if session.view(table_name)
        raise SQLError.new("cannot modify #{table_name} because it is a view")
      end
      if Session::MASTER_NAMES.includes?(table_name.downcase) || Session::TEMP_MASTER_NAMES.includes?(table_name.downcase)
        raise UnsupportedSQL.new("writing #{table_name} under PRAGMA writable_schema") if session.writable_schema?
        raise SQLError.new("table #{table_name} may not be modified")
      end
      session.write_table(table_name, schema_text) || raise SQLError.new("no such table: #{schema_text ? "#{schema_text}." : ""}#{table_name}")
    end
  end

  # UPDATE (lang_update.html), with FROM, conflict clauses and RETURNING.
  class UpdatePlan < StatementPlan
    @table : WriteTable
    @assignments : AssignmentList
    @targets : TargetRows
    @override : ConflictAction
    @returning : RowProgram?
    @statement : SQL::Update
    @trigger_programs : TriggerProgramCache?
    # The SET list's column names as written (UPDATE OF triggers match them).
    @list_of_changed_names : Array(String)
    # The row arrays each target is read and rebuilt in, kept for the next run.
    @spare_scratch : RowScratch? = nil
    # The SET list, evaluated against each target as the second pass reads
    # it again, when a trigger can change rows between the scan and the
    # write (nil: the scan computes the values).
    @current_values : RowProgram? = nil

    # *override* is the conflict policy of the statement whose trigger runs
    # this one: when it gave one, it replaces this statement's own.
    def initialize(@session : Session, statement : SQL::Update, override : ConflictAction = ConflictAction::Default)
      @statement = statement
      @table = WritableTarget.check(@session, statement.table)
      info = @table.table_info
      generated = @table.list_of_columns.select(&.generated?).map(&.position).to_set
      @assignments = AssignmentList.compile(info, statement.assignments, generated)
      @override = override.default? ? ConflictAction.from(statement.conflict) : override
      @list_of_changed_names = statement.assignments.flat_map(&.columns).map(&.value)
      columns = RowProgram.columns(@assignments.list_of_expressions)
      # C computes the SET list in the second pass, from the row as it is
      # then (an UPDATE ... FROM, from the first pass's ephemeral table).
      # A trigger, or a foreign key action, run for an earlier row can
      # change a later one before it is written; any other table keeps
      # computing the values in the scan.
      if statement.from.nil? && (!@table.list_of_triggers(@session).empty? || @table.has_writing_foreign_key_actions?(@session))
        current = PseudoTable.new(statement.table.alias_name.try(&.value) || info.name, info, outermost_only: true)
        @current_values = RowProgram.new(@session, columns, [current], with_clause: statement.with_clause)
        columns = [] of SQL::ResultColumn
      end
      @targets = TargetRows.new(@session, info, statement.table, statement.indexed_by, statement.not_indexed,
        columns, statement.from, statement.where, statement.with_clause)
      if returning = statement.returning
        # RETURNING names the table, never its alias.
        pseudo = PseudoTable.new(info.name, info, outermost_only: true)
        program = RowProgram.new(@session, returning, [pseudo], returning: true)
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
      # A loop among the generated columns fails the statement when it is
      # prepared, whatever rows it would write.
      @table.list_of_generated_in_order(@session)
      @trigger_programs = TriggerProgramCache.for_plan(@session, @table.list_of_triggers(@session), @table.trigger_target,
        SQL::TriggerEvent::Update, @list_of_changed_names, @override)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = @returning ? [] of Array(Value) : NO_ROWS
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        journal, _, in_rowid_order = update_choices
        run.statement_journal = journal
        run.trigger_programs = @trigger_programs
        if program = @returning
          run.returning = ReturningRows.new(program, list_of_parameters, returned)
        end
        write_returning_rows(run, list_of_parameters, in_rowid_order)
      end
      returned
    end

    def write_rows(run : WriteRun, list_of_parameters : Array(Value)) : Nil
      write_returning_rows(run, list_of_parameters, update_choices[2])
    end

    # The statement journal and whether rows go in rowid order.
    private def update_choices : Tuple(Bool, Bool, Bool)
      positions = @assignments.list_of_positions
      journal_choices(@session.foreign_keys?) do
        if @table.has_triggers_for?(@session, SQL::TriggerEvent::Update)
          # A trigger makes the UPDATE a two-pass multi-write.
          {true, false, true}
        else
          {StatementJournal.for_update(@session, @table, @statement, @override, positions), false,
           StatementJournal.update_in_rowid_order?(@session, @table, @statement, @override, positions, @targets.scan_index_root)}
        end
      end
    end

    private def write_returning_rows(run : WriteRun, list_of_parameters : Array(Value), in_rowid_order : Bool) : Nil
      @targets.collect(list_of_parameters) do |collected|
        write_target_rows(run, list_of_parameters, in_rowid_order, collected)
      end
    end

    # Writes the collected targets; the list is the one TargetRows#collect
    # keeps for its next run, so only this call reads it.
    private def write_target_rows(run : WriteRun, list_of_parameters : Array(Value), in_rowid_order : Bool,
                                  targets : Array({Int64?, Array(Value), Array(Value)})) : Nil
      positions = @assignments.list_of_positions
      if !@table.without_rowid? && in_rowid_order && targets.size > 1
        targets = targets.sort_by { |target| target[0] || 0_i64 }
      elsif @table.without_rowid? && !WithoutRowidScan.primary_key_changed?(@table, positions)
        read = @statement.assignments.map(&.value)
        layout = WithoutRowidScan.scan_layout(@table, @statement.where, read)
        if layout && !StatementJournal.update_in_rowid_order?(@session, @table, @statement, @override, positions, layout.entry.root_page)
          targets = WithoutRowidScan.sort(@table, targets, layout)
        end
      end
      scratch = @spare_scratch || RowScratch.new
      @spare_scratch = nil
      begin
        write_targets_with(scratch, run, list_of_parameters, targets)
      ensure
        @spare_scratch = scratch
      end
    end

    # Writes each target, reading its row into *scratch*.
    private def write_targets_with(scratch : RowScratch, run : WriteRun, list_of_parameters : Array(Value),
                                   targets : Array({Int64?, Array(Value), Array(Value)})) : Nil
      positions = @assignments.list_of_positions
      program = @current_values
      # One frame for the run: an uncorrelated subquery of the SET list is
      # computed once, as C's OP_Once does.
      frame = program.try(&.frame_for_run(list_of_parameters))
      targets.each do |rowid, snapshot, values|
        old = rowid ? @table.database.row_at(@table.layout, rowid, scratch.old_row) : @table.database.row_with_key_of(@table.layout, snapshot)
        next unless old
        if program && frame
          values = values_for_current_row(program, frame, run, rowid, old)
        end
        new_row = scratch.new_row_from(old)
        explicit_rowid = nil.as(Value)
        positions.each_with_index do |position, index|
          if position < 0
            explicit_rowid = values[index]
          else
            new_row[position] = values[index]
          end
        end
        begin
          run.update_row(@table, rowid, old, new_row, explicit_rowid, @override, positions, @list_of_changed_names)
        rescue TriggerIgnore
        end
      end
    end

    # The SET list's values for the row *old* at *rowid*, as it is now.
    private def values_for_current_row(program : RowProgram, frame : Frame, run : WriteRun, rowid : Int64?,
                                       old : Array(Value)) : Array(Value)
      run.fill_virtual_columns(@table, old, rowid)
      current = program.list_of_pseudo_tables[0]
      current.row = old
      current.rowid = rowid
      program.evaluate_in(frame) || raise Error.new("the SET list of an UPDATE returned no row")
    end
  end

  # DELETE (lang_delete.html), with RETURNING.
  class DeletePlan < StatementPlan
    @table : WriteTable
    @targets : TargetRows
    @returning : RowProgram?
    @statement : SQL::Delete
    @trigger_programs : TriggerProgramCache?
    # The row array each target is read into, kept for the next run.
    @spare_scratch : RowScratch? = nil

    def initialize(@session : Session, statement : SQL::Delete)
      @statement = statement
      @table = WritableTarget.check(@session, statement.table)
      info = @table.table_info
      @targets = TargetRows.new(@session, info, statement.table, statement.indexed_by, statement.not_indexed,
        [] of SQL::ResultColumn, nil, statement.where, statement.with_clause)
      if returning = statement.returning
        # RETURNING names the table, never its alias.
        pseudo = PseudoTable.new(info.name, info, outermost_only: true)
        program = RowProgram.new(@session, returning, [pseudo], returning: true)
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
      @trigger_programs = TriggerProgramCache.for_plan(@session, @table.list_of_triggers(@session), @table.trigger_target,
        SQL::TriggerEvent::Delete, nil, ConflictAction::Default)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = @returning ? [] of Array(Value) : NO_ROWS
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        journal, _, in_rowid_order = delete_choices
        run.statement_journal = journal
        run.trigger_programs = @trigger_programs
        if program = @returning
          run.returning = ReturningRows.new(program, list_of_parameters, returned)
        end
        write_returning_rows(run, list_of_parameters, in_rowid_order)
      end
      returned
    end

    def write_rows(run : WriteRun, list_of_parameters : Array(Value)) : Nil
      write_returning_rows(run, list_of_parameters, delete_choices[2])
    end

    # The statement journal and whether rows go in rowid order.
    private def delete_choices : Tuple(Bool, Bool, Bool)
      journal_choices(@session.foreign_keys?) do
        if @table.has_triggers_for?(@session, SQL::TriggerEvent::Delete)
          {true, false, true}
        else
          {StatementJournal.for_delete(@session, @table, @statement), false,
           StatementJournal.delete_in_rowid_order?(@session, @table, @statement)}
        end
      end
    end

    private def write_returning_rows(run : WriteRun, list_of_parameters : Array(Value), in_rowid_order : Bool) : Nil
      @targets.collect(list_of_parameters) do |collected|
        write_target_rows(run, list_of_parameters, in_rowid_order, collected)
      end
    end

    # Writes the collected targets; the list is the one TargetRows#collect
    # keeps for its next run, so only this call reads it.
    private def write_target_rows(run : WriteRun, list_of_parameters : Array(Value), in_rowid_order : Bool,
                                  targets : Array({Int64?, Array(Value), Array(Value)})) : Nil
      if !@table.without_rowid? && in_rowid_order && targets.size > 1
        targets = targets.sort_by { |target| target[0] || 0_i64 }
      elsif @table.without_rowid? && !in_rowid_order
        if layout = WithoutRowidScan.scan_layout(@table, @statement.where, [] of SQL::Expression)
          targets = WithoutRowidScan.sort(@table, targets, layout)
        end
      end
      scratch = @spare_scratch || RowScratch.new
      @spare_scratch = nil
      begin
        write_targets_with(scratch, run, list_of_parameters, targets)
      ensure
        @spare_scratch = scratch
      end
    end

    # Writes each target, reading its row into *scratch*.
    private def write_targets_with(scratch : RowScratch, run : WriteRun, list_of_parameters : Array(Value),
                                   targets : Array({Int64?, Array(Value), Array(Value)})) : Nil
      targets.each do |rowid, snapshot, _values|
        old = rowid ? @table.database.row_at(@table.layout, rowid, scratch.old_row) : @table.database.row_with_key_of(@table.layout, snapshot)
        next unless old
        begin
          run.delete_row(@table, rowid, old)
        rescue TriggerIgnore
        end
      end
    end
  end
end
