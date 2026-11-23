module Grant::SQLiteEngine::Query
  # The rows an UPDATE or DELETE changes: a SELECT over the target table
  # (and an UPDATE's FROM) whose result columns are the values to compute,
  # run to the end before the first write, with the target row's rowid and
  # values read from its frame slot.
  class TargetRows
    getter list_of_column_names : Array(String)

    @compiled : CompiledSelect
    @slot : Int32
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
    end

    # Every target row once (the first match of an UPDATE ... FROM): its
    # rowid (nil for WITHOUT ROWID), its values and the computed columns.
    def collect(list_of_parameters : Array(Value)) : Array({Int64?, Array(Value), Array(Value)})
      frame = Frame.new(@compiled.slot_count, @compiled.aggregate_count, list_of_parameters, @session)
      producer = @compiled.producer
      producer.open(frame)
      rows = [] of {Int64?, Array(Value), Array(Value)}
      seen = Set(Int64).new
      while values = producer.next_row(frame)
        rowid = frame.list_of_rowids[@slot]
        if rowid
          next unless seen.add?(rowid)
        end
        rows << {rowid, frame.list_of_rows[@slot].dup, values}
      end
      rows
    end
  end

  # Checks shared by UPDATE and DELETE: the target must be a writable table.
  module WritableTarget
    def self.check(session : Session, reference : SQL::QualifiedTable) : WriteTable
      table_name = reference.name.value
      schema = reference.schema
      if schema && !schema.same?("main") && !schema.same?("temp")
        raise SQLError.new("unknown database #{schema.value}")
      end
      schema_text = schema.try(&.value)
      if session.view(table_name)
        raise SQLError.new("cannot modify #{table_name} because it is a view")
      end
      if Session::MASTER_NAMES.includes?(table_name.downcase) || Session::TEMP_MASTER_NAMES.includes?(table_name.downcase)
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
    @returning_pseudo : PseudoTable?
    @statement : SQL::Update

    def initialize(@session : Session, statement : SQL::Update)
      @statement = statement
      @table = WritableTarget.check(@session, statement.table)
      info = @table.table_info
      generated = @table.list_of_columns.select(&.generated?).map(&.position).to_set
      @assignments = AssignmentList.compile(info, statement.assignments, generated)
      @override = ConflictAction.from(statement.conflict)
      @targets = TargetRows.new(@session, info, statement.table, statement.indexed_by, statement.not_indexed,
        RowProgram.columns(@assignments.list_of_expressions), statement.from, statement.where, statement.with_clause)
      if returning = statement.returning
        pseudo = PseudoTable.new(statement.table.alias_name.try(&.value) || info.name, info)
        @returning_pseudo = pseudo
        program = RowProgram.new(@session, returning, [pseudo])
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = [] of Array(Value)
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        positions = @assignments.list_of_positions
        run.statement_journal = StatementJournal.for_update(@session, @table, @statement, @override, positions)
        targets = @targets.collect(list_of_parameters)
        if !@table.without_rowid? && StatementJournal.update_in_rowid_order?(@session, @table, @statement, @override, positions, @targets.scan_index_root)
          targets = targets.sort_by { |target| target[0] || 0_i64 }
        end
        targets.each do |rowid, snapshot, values|
          old = rowid ? @table.database.row_at(@table.layout, rowid) : @table.database.row_with_key_of(@table.layout, snapshot)
          next unless old
          new_row = old.dup
          explicit_rowid = nil.as(Value)
          positions.each_with_index do |position, index|
            if position < 0
              explicit_rowid = values[index]
            else
              new_row[position] = values[index]
            end
          end
          # A row an IGNORE conflict skipped returns nothing.
          updated = run.update_row(@table, rowid, old, new_row, explicit_rowid, @override, positions)
          next unless updated
          new_rowid, stored = updated
          if program = @returning
            pseudo = @returning_pseudo || raise Error.new("RETURNING without its row")
            pseudo.row = stored
            pseudo.rowid = new_rowid
            if returned_row = program.evaluate(list_of_parameters)
              returned << returned_row
            end
          end
        end
      end
      returned
    end
  end

  # DELETE (lang_delete.html), with RETURNING.
  class DeletePlan < StatementPlan
    @table : WriteTable
    @targets : TargetRows
    @returning : RowProgram?
    @returning_pseudo : PseudoTable?
    @statement : SQL::Delete

    def initialize(@session : Session, statement : SQL::Delete)
      @statement = statement
      @table = WritableTarget.check(@session, statement.table)
      info = @table.table_info
      @targets = TargetRows.new(@session, info, statement.table, statement.indexed_by, statement.not_indexed,
        [] of SQL::ResultColumn, nil, statement.where, statement.with_clause)
      if returning = statement.returning
        pseudo = PseudoTable.new(statement.table.alias_name.try(&.value) || info.name, info)
        @returning_pseudo = pseudo
        program = RowProgram.new(@session, returning, [pseudo])
        @returning = program
        @list_of_column_names = program.list_of_column_names
      end
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      returned = [] of Array(Value)
      @session.run_write(list_of_parameters, returning: !@returning.nil?) do |run|
        run.statement_journal = StatementJournal.for_delete(@session, @table, @statement)
        targets = @targets.collect(list_of_parameters)
        if !@table.without_rowid? && StatementJournal.delete_in_rowid_order?(@session, @table, @statement)
          targets = targets.sort_by { |target| target[0] || 0_i64 }
        end
        targets.each do |rowid, snapshot, _values|
          old = rowid ? @table.database.row_at(@table.layout, rowid) : @table.database.row_with_key_of(@table.layout, snapshot)
          next unless old
          if program = @returning
            pseudo = @returning_pseudo || raise Error.new("RETURNING without its row")
            pseudo.row = old
            pseudo.rowid = rowid
            if returned_row = program.evaluate(list_of_parameters)
              returned << returned_row
            end
          end
          run.delete_row(@table, rowid, old)
        end
      end
      returned
    end
  end
end
