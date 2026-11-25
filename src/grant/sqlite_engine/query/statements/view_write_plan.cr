module Grant::SQLiteEngine::Query
  module StatementCompiler
    # The plan of an INSERT: a view's INSTEAD OF INSERT triggers when the
    # target is a view that has them, else the table's InsertPlan.
    # *override* is the conflict policy of the statement whose trigger
    # runs this one (Default at the top level).
    def self.insert_plan(session : Session, statement : SQL::Insert, override : ConflictAction = ConflictAction::Default) : StatementPlan
      if view = ViewWritePlan.view_with_triggers(session, statement.table, SQL::TriggerEvent::Insert)
        return ViewWritePlan.new(session, view, statement, override)
      end
      InsertPlan.new(session, statement, override)
    end

    def self.update_plan(session : Session, statement : SQL::Update, override : ConflictAction = ConflictAction::Default) : StatementPlan
      names = statement.assignments.flat_map(&.columns).map(&.value)
      if view = ViewWritePlan.view_with_triggers(session, statement.table, SQL::TriggerEvent::Update, names)
        return ViewWritePlan.new(session, view, statement, override)
      end
      UpdatePlan.new(session, statement, override)
    end

    def self.delete_plan(session : Session, statement : SQL::Delete) : StatementPlan
      if view = ViewWritePlan.view_with_triggers(session, statement.table, SQL::TriggerEvent::Delete)
        return ViewWritePlan.new(session, view, statement, ConflictAction::Default)
      end
      DeletePlan.new(session, statement)
    end
  end

  # INSERT, UPDATE or DELETE on a view with INSTEAD OF triggers for it
  # (lang_createtrigger.html#instead_of_triggers): each row the statement
  # would write runs the triggers, with OLD the view's row and NEW the row
  # as the statement makes it. The statement itself changes nothing, so
  # changes() stays 0.
  class ViewWritePlan < StatementPlan
    @target : TriggerTarget
    @list_of_triggers : Array(TriggerDefinition)
    @event : SQL::TriggerEvent
    @override : ConflictAction
    # The rows to write: the source of an INSERT, or for UPDATE and DELETE
    # the view's rows the WHERE selects, each followed by the SET values.
    @rows : CompiledSelect?
    # Per source column (INSERT) or SET value (UPDATE), the view column it
    # fills.
    @list_of_positions = [] of Int32
    @list_of_changed_names : Array(String)? = nil
    @trigger_programs : TriggerProgramCache?

    # The view *reference* names when it has an INSTEAD OF trigger for
    # *event*, or nil.
    def self.view_with_triggers(session : Session, reference : SQL::QualifiedTable, event : SQL::TriggerEvent,
                                list_of_changed_names : Array(String)? = nil) : ViewInfo?
      if schema = reference.schema
        return unless session.database_named(schema.value).same?(session.database)
      end
      name = reference.name.value
      return if session.table(name)
      view = session.view(name)
      return unless view
      list = session.list_of_triggers_on(view.name, session.database)
      list.any? { |trigger| trigger.event == event && trigger.fires_for?(list_of_changed_names) } ? view : nil
    end

    def initialize(@session : Session, view : ViewInfo, statement : SQL::Insert | SQL::Update | SQL::Delete,
                   override : ConflictAction)
      @list_of_triggers = @session.list_of_triggers_on(view.name, @session.database)
      @target = ViewWritePlan.target_of(@session, view)
      case statement
      when SQL::Insert
        @event = SQL::TriggerEvent::Insert
        @override = statement.verb.replace? ? ConflictAction::Replace : ConflictAction.from(statement.conflict)
        @override = override unless override.default?
        compile_insert(view, statement)
      when SQL::Update
        @event = SQL::TriggerEvent::Update
        @override = override.default? ? ConflictAction.from(statement.conflict) : override
        compile_update(view, statement)
      else
        @event = SQL::TriggerEvent::Delete
        @override = ConflictAction::Default
        raise UnsupportedSQL.new("RETURNING on a view") if statement.returning
        @rows = view_rows(statement.table, [] of SQL::ResultColumn, statement.where, statement.with_clause)
      end
      @trigger_programs = TriggerProgramCache.for_plan(@session, @list_of_triggers, @target, @event,
        @list_of_changed_names, @override)
    end

    # The view's columns as NEW and OLD read them: names made unique as
    # sqlite3ColumnsFromExprList makes them, the affinities
    # sqlite3SubqueryColumnTypes gives them.
    def self.target_of(session : Session, view : ViewInfo) : TriggerTarget
      plan = Compiler.new(session).view_plan(view)
      names = Compiler.unique_names(plan.list_of_column_names)
      affinities = plan.list_of_column_affinities
      collations = names.map_with_index { |_, index| plan.list_of_collations[index]? || Collation::Binary }
      if declared = view.list_of_column_names
        # sqlite3ViewGetColumnNames types the declared columns only when
        # their count is the select list's as written (a `*` counts once).
        last = view.query.cores.last?
        written = last.is_a?(SQL::SelectClause) ? last.columns.size : names.size
        unless declared.size == written && declared.size == names.size
          affinities = Array(ExpressionAffinity).new(declared.size, ExpressionAffinity::None)
          collations = Array(Collation).new(declared.size, Collation::Binary)
        end
        names = declared
      end
      TriggerTarget.new(names, affinities, collations, nil, false, false)
    end

    private def compile_insert(view : ViewInfo, statement : SQL::Insert) : Nil
      raise SQLError.new("cannot UPSERT a view") unless statement.upserts.empty?
      raise UnsupportedSQL.new("RETURNING on a view") if statement.returning
      width = @target.list_of_column_names.size
      positions = if columns = statement.columns
                    columns.map do |column|
                      @target.column_index(column.value) || raise SQLError.new("table #{view.name} has no column named #{column.value}")
                    end
                  else
                    (0...width).to_a
                  end
      source = statement.source
      return unless source
      query = source
      if with_clause = statement.with_clause
        query = SQL::SelectStatement.new(with_clause, source.cores, source.operators, source.order_by, source.limit)
      end
      compiled = Compiler.new(@session).compile(query)
      supplied = compiled.list_of_column_names.size
      if statement.columns.nil? && supplied != positions.size
        raise SQLError.new("table #{view.name} has #{positions.size} columns but #{supplied} values were supplied")
      end
      if statement.columns && supplied != positions.size
        raise SQLError.new("#{supplied} values for #{positions.size} columns")
      end
      @list_of_positions = positions
      @rows = compiled
    end

    private def compile_update(view : ViewInfo, statement : SQL::Update) : Nil
      raise UnsupportedSQL.new("RETURNING on a view") if statement.returning
      raise UnsupportedSQL.new("UPDATE ... FROM on a view") if statement.from
      names = [] of String
      expressions = [] of SQL::Expression
      statement.assignments.each do |assignment|
        raise UnsupportedSQL.new("row-value SET on a view") if assignment.columns.size > 1
        column = assignment.columns[0]
        position = @target.column_index(column.value) || raise SQLError.new("no such column: #{column.value}")
        names << column.value
        @list_of_positions << position
        expressions << assignment.value
      end
      @list_of_changed_names = names
      columns = [SQL::AllColumns.new(nil).as(SQL::ResultColumn)] + RowProgram.columns(expressions)
      @rows = view_rows(statement.table, columns, statement.where, statement.with_clause)
    end

    # sqlite3MaterializeView: the view's rows the WHERE selects.
    private def view_rows(reference : SQL::QualifiedTable, columns : Array(SQL::ResultColumn), where : SQL::Expression?,
                          with_clause : SQL::WithClause?) : CompiledSelect
      source = SQL::TableReference.new(nil, reference.name, reference.alias_name, nil, false)
      columns = [SQL::AllColumns.new(nil).as(SQL::ResultColumn)] if columns.empty?
      core = SQL::SelectClause.new(SQL::DistinctMode::None, columns, SQL::From.new([SQL::FromItem.new(nil, source, nil, nil)]),
        where, [] of SQL::Expression, nil, [] of SQL::WindowDefinition)
      query = SQL::SelectStatement.new(with_clause, [core] of SQL::SelectCore, [] of SQL::CompoundOperator,
        [] of SQL::OrderingTerm, nil)
      Compiler.new(@session).compile(query)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      @session.run_write(list_of_parameters) do |run|
        run.trigger_programs = @trigger_programs
        write_rows(run, list_of_parameters)
      end
      NO_ROWS
    end

    def write_rows(run : WriteRun, list_of_parameters : Array(Value)) : Nil
      width = @target.list_of_column_names.size
      each_row(list_of_parameters) do |values|
        begin
          case @event
          when .insert?
            new = Array(Value).new(width, nil)
            @list_of_positions.each_with_index { |position, index| new[position] = values[index] }
            run.fire_triggers(@list_of_triggers, @target, @event, true, nil, nil, nil, new, @override)
          when .update?
            old = values[0, width]
            new = old.dup
            @list_of_positions.each_with_index { |position, index| new[position] = values[width + index] }
            run.fire_triggers(@list_of_triggers, @target, @event, true, nil, old, nil, new, @override, @list_of_changed_names)
          else
            run.fire_triggers(@list_of_triggers, @target, @event, true, nil, values[0, width], nil, nil, @override)
          end
        rescue TriggerIgnore
        end
      end
    end

    # The rows, read in full before the first trigger runs.
    private def each_row(list_of_parameters : Array(Value), & : Array(Value) ->) : Nil
      compiled = @rows
      unless compiled
        yield [] of Value
        return
      end
      frame = Frame.new(compiled.slot_count, compiled.aggregate_count, list_of_parameters, @session)
      producer = compiled.producer
      producer.open(frame)
      rows = [] of Array(Value)
      while row = producer.next_row(frame)
        rows << row.dup
      end
      rows.each { |row| yield row }
    end
  end
end

module Grant::SQLiteEngine::Query
  class Compiler
    # The plan of *view*'s query, compiled as a FROM item reads it (its
    # missing tables are reported with their schema).
    def view_plan(view : ViewInfo) : QueryPlan
      compile_view(view)
    end
  end
end
