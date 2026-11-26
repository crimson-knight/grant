module Grant::SQLiteEngine::Query
  # The columns a trigger's NEW and OLD rows have: the table's (or the
  # view's) names, affinities and collations. *realify*: a REAL column
  # reads an integer as a real (OP_RealAffinity after OP_Param), which a
  # view's columns, holding values as computed, never need.
  record TriggerTarget, list_of_column_names : Array(String), list_of_affinities : Array(ExpressionAffinity),
    list_of_collations : Array(Collation), rowid_alias : Int32?, realify : Bool, has_rowid : Bool do
    def self.for_table(table : TableInfo) : TriggerTarget
      new(table.list_of_column_names, table.list_of_affinities, table.list_of_collations,
        table.without_rowid? ? nil : table.rowid_alias, true, !table.without_rowid?)
    end

    def column_index(name : String) : Int32?
      @list_of_column_names.index { |column| column.compare(name, case_insensitive: true) == 0 }
    end
  end

  # The row NEW or OLD names inside one compiled trigger program, filled
  # each time the program fires.
  class TriggerRow
    getter target : TriggerTarget
    property row : Array(Value) = [] of Value
    property rowid : Int64? = nil

    def initialize(@target : TriggerTarget)
    end
  end

  # What NEW and OLD mean while a trigger program compiles (lookupName's
  # pParse->pTriggerTab): NEW for INSERT and UPDATE, OLD for UPDATE and
  # DELETE.
  class TriggerScope
    getter new_row : TriggerRow?
    getter old_row : TriggerRow?

    def initialize(@new_row : TriggerRow?, @old_row : TriggerRow?)
    end

    # The expression `table_name.column_name` reads, or nil when the name
    # is neither NEW nor OLD or the row has no such column. The INTEGER
    # PRIMARY KEY and the rowid names read the rowid.
    def resolve(table_name : String, column_name : String) : Expr?
      trigger_row = if table_name.compare("new", case_insensitive: true) == 0
                      @new_row
                    elsif table_name.compare("old", case_insensitive: true) == 0
                      @old_row
                    end
      return unless trigger_row
      target = trigger_row.target
      if position = target.column_index(column_name)
        return TriggerColumnExpr.new(trigger_row, position == target.rowid_alias ? -1 : position)
      end
      if target.has_rowid && ExpressionCompiler::ROWID_NAMES.includes?(column_name.downcase)
        return TriggerColumnExpr.new(trigger_row, -1)
      end
      nil
    end
  end

  # A column of NEW or OLD (TK_TRIGGER), *column* -1 for the rowid. It has
  # no affinity of its own (sqlite3ExprAffinity reads only TK_COLUMN),
  # except the rowid's INTEGER; it compares with the column's collation.
  class TriggerColumnExpr < Expr
    def initialize(@trigger_row : TriggerRow, @column : Int32)
    end

    def evaluate(frame : Frame) : Value
      column = @column
      return @trigger_row.rowid if column < 0
      value = @trigger_row.row[column]? || nil
      if value.is_a?(Int64) && @trigger_row.target.realify && @trigger_row.target.list_of_affinities[column].real?
        return value.to_f64
      end
      value
    end

    def affinity : ExpressionAffinity
      @column < 0 ? ExpressionAffinity::Integer : ExpressionAffinity::None
    end

    def collation_sequence : Collation?
      column = @column
      return if column < 0
      @trigger_row.target.list_of_collations[column]
    end

    def column_name? : String?
      column = @column
      column < 0 ? "rowid" : @trigger_row.target.list_of_column_names[column]
    end
  end

  # RAISE(IGNORE): ends the trigger program and every program still to
  # run for the row; the statement that fired it goes on with its next
  # row, keeping what it already changed.
  class TriggerIgnore < Exception
  end

  # RAISE(ROLLBACK | ABORT | FAIL, message): the statement fails with
  # *message* as a constraint error, resolved by the action named.
  class RaiseExpr < Expr
    def initialize(@action : SQL::RaiseAction, @message : Expr?)
    end

    def evaluate(frame : Frame) : Value
      raise TriggerIgnore.new if @action.ignore?
      message = @message.try(&.evaluate(frame))
      text = message.is_a?(Bytes) ? String.new(message) : message.to_s
      action = case @action
               when .rollback? then ConflictAction::Rollback
               when .fail?     then ConflictAction::Fail
               else                 ConflictAction::Abort
               end
      raise ConstraintError.new(text, action)
    end
  end

  class Session
    # NEW and OLD while a trigger program's statements compile.
    property trigger_scope : TriggerScope? = nil
    # The programs the statement being compiled shares (pRoot->pTriggerPrg):
    # every trigger it can fire, directly or from another trigger, is
    # compiled once per conflict policy.
    property trigger_compilation : TriggerProgramCache? = nil

    # Runs the block with *scope* as the compile-time NEW and OLD.
    def with_trigger_scope(scope : TriggerScope?, & : -> T) : T forall T
      saved = @trigger_scope
      @trigger_scope = scope
      begin
        yield
      ensure
        @trigger_scope = saved
      end
    end
  end

  # The trigger programs one top-level statement runs, by trigger and
  # conflict policy (getRowTrigger's list).
  class TriggerProgramCache
    @programs = {} of {TriggerDefinition, ConflictAction} => TriggerProgram

    # Compiles, or finds, the programs of the triggers in *list* that
    # *event* fires, as a write plan does while it compiles: a body error
    # fails the statement before it runs.
    def self.for_plan(session : Session, list : Array(TriggerDefinition), target : TriggerTarget, event : SQL::TriggerEvent,
                      list_of_changed_names : Array(String)?, override : ConflictAction) : TriggerProgramCache?
      cache = session.trigger_compilation
      matching = list.select { |trigger| trigger.event == event && trigger.fires_for?(list_of_changed_names) }
      return cache if matching.empty?
      cache ||= TriggerProgramCache.new
      matching.each { |trigger| cache.program_for(session, trigger, target, override) }
      cache
    end

    # The program of *trigger* with *override*; a program that is running
    # already (a recursive trigger) gets a fresh copy, so its NEW and OLD
    # stay its own.
    def program_for(session : Session, trigger : TriggerDefinition, target : TriggerTarget, override : ConflictAction) : TriggerProgram
      key = {trigger, override}
      if existing = @programs[key]?
        return existing unless existing.running?
        # A list of its own, where the copy's body finds the copy.
        return TriggerProgramCache.new.program_for(session, trigger, target, override)
      end
      compile(session, trigger, target, override)
    end

    private def compile(session : Session, trigger : TriggerDefinition, target : TriggerTarget, override : ConflictAction) : TriggerProgram
      program = TriggerProgram.new(trigger, target)
      # In the list before its body compiles: a body that fires its own
      # trigger finds it there (codeRowTrigger links it first).
      @programs[{trigger, override}] = program
      saved = session.trigger_compilation
      session.trigger_compilation = self
      begin
        program.compile(session, override)
      ensure
        session.trigger_compilation = saved
      end
      program
    end
  end

  # One step of a trigger body: an INSERT, UPDATE or DELETE plan, or a
  # SELECT whose rows are discarded.
  class SelectStepPlan < StatementPlan
    def initialize(@session : Session, statement : SQL::SelectStatement)
      @compiled = Compiler.new(@session).compile(statement)
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      NO_ROWS
    end

    def write_rows(run : WriteRun, list_of_parameters : Array(Value)) : Nil
      frame = Frame.new(@compiled.slot_count, @compiled.aggregate_count, list_of_parameters, @session)
      producer = @compiled.producer
      producer.open(frame)
      while producer.next_row(frame)
      end
    end
  end

  # A trigger compiled for one conflict policy (codeRowTrigger): its WHEN
  # and body statements, resolved against its own NEW and OLD rows.
  class TriggerProgram
    getter trigger : TriggerDefinition
    getter? running = false
    getter new_row : TriggerRow
    getter old_row : TriggerRow

    @when : RowProgram? = nil
    @list_of_steps = [] of StatementPlan

    # No parameters reach a trigger body ("trigger cannot use variables").
    NO_PARAMETERS = [] of Value

    def initialize(@trigger : TriggerDefinition, target : TriggerTarget)
      @new_row = TriggerRow.new(target)
      @old_row = TriggerRow.new(target)
    end

    # The body's ON CONFLICT: the firing statement's when it gave one,
    # else each step's own (codeTriggerProgram's eOrconf).
    def compile(session : Session, override : ConflictAction) : Nil
      event = @trigger.event
      scope = TriggerScope.new(event.delete? ? nil : @new_row, event.insert? ? nil : @old_row)
      session.with_trigger_scope(scope) do
        if condition = @trigger.statement.when_condition
          @when = RowProgram.new(session, RowProgram.columns([condition] of SQL::Expression), [] of PseudoTable)
        end
        schema = @trigger.database.same?(session.temp_database) ? nil : session.schema_name_of(@trigger.database)
        @trigger.statement.body.each do |statement|
          @list_of_steps << TriggerProgram.step_plan(session, TriggerProgram.in_schema(statement, schema), override)
        end
      end
    end

    # sqlite3TriggerStepSrc: the target of a step of a trigger outside
    # TEMP is a table of the trigger's own database.
    def self.in_schema(statement : SQL::Statement, schema : String?) : SQL::Statement
      return statement unless schema
      case statement
      when SQL::Insert
        SQL::Insert.new(statement.with_clause, statement.verb, statement.conflict, qualified(statement.table, schema),
          statement.columns, statement.source, statement.upserts, statement.returning)
      when SQL::Update
        SQL::Update.new(statement.with_clause, statement.conflict, qualified(statement.table, schema), statement.indexed_by,
          statement.not_indexed, statement.assignments, statement.from, statement.where, statement.returning)
      when SQL::Delete
        SQL::Delete.new(statement.with_clause, qualified(statement.table, schema), statement.indexed_by,
          statement.not_indexed, statement.where, statement.returning)
      else
        statement
      end
    end

    private def self.qualified(table : SQL::QualifiedTable, schema : String) : SQL::QualifiedTable
      SQL::QualifiedTable.new(SQL::Name.bare(schema), table.name, table.alias_name)
    end

    def self.step_plan(session : Session, statement : SQL::Statement, override : ConflictAction) : StatementPlan
      case statement
      when SQL::Insert          then StatementCompiler.insert_plan(session, statement, override)
      when SQL::Update          then StatementCompiler.update_plan(session, statement, override)
      when SQL::Delete          then StatementCompiler.delete_plan(session, statement)
      when SQL::SelectStatement then SelectStepPlan.new(session, statement)
      else
        raise UnsupportedSQL.new("#{PreparedQuery.statement_kind(statement)} in a trigger")
      end
    end

    # Runs the program for one row (OP_Program): skipped when WHEN is not
    # true; each body step's changes count in total_changes() as the step
    # ends (OP_ResetCount).
    def fire(run : WriteRun, old_rowid : Int64?, old : Array(Value)?, new_rowid : Int64?, new : Array(Value)?) : Nil
      @running = true
      if old
        @old_row.row = old
        @old_row.rowid = old_rowid
      end
      if new
        @new_row.row = new
        @new_row.rowid = new_rowid
      end
      state = run.enter_trigger(@trigger)
      begin
        if condition = @when
          value = condition.evaluate(NO_PARAMETERS).try(&.[0]?)
          return unless ValueSemantics.truth(value) == true
        end
        @list_of_steps.each do |step|
          step.write_rows(run, NO_PARAMETERS)
          run.finish_trigger_step unless step.is_a?(SelectStepPlan)
        end
      ensure
        run.leave_trigger(state)
        @running = false
      end
    end
  end

  # What a trigger program saves of the statement that fired it, and
  # gives back when it ends (sqlite3VdbeFrameRestore).
  record TriggerFrameState, nested : Int32, step_changes : Int64, last_insert_rowid : Int64, changes : Int64

  class WriteTable
    @list_of_triggers : Array(TriggerDefinition)? = nil

    # The triggers on this table, in firing order.
    def list_of_triggers(session : Session) : Array(TriggerDefinition)
      @list_of_triggers ||= session.list_of_triggers_on(@table_info.name, @table_info.database)
    end

    getter trigger_target : TriggerTarget { TriggerTarget.for_table(@table_info) }

    # True when a trigger fires for *event* on this table.
    def has_triggers_for?(session : Session, event : SQL::TriggerEvent) : Bool
      list_of_triggers(session).any? { |trigger| trigger.event == event }
    end
  end

  class WriteRun
    # SQLITE_MAX_TRIGGER_DEPTH.
    MAX_TRIGGER_DEPTH = 1000

    # The trigger programs the statement compiled; programs for triggers
    # it did not foresee (a foreign key action's table) are added.
    property trigger_programs : TriggerProgramCache? = nil
    # How many trigger programs are running.
    getter trigger_depth = 0
    # Rows the running trigger step changed (Vdbe.nChange of its frame).
    @step_changes = 0_i64
    # Made when the first trigger fires: most statements fire none.
    private getter list_of_running_triggers : Array(TriggerDefinition) { [] of TriggerDefinition }

    # Fires the triggers of *table* that *event* fires at this time.
    def fire_table_triggers(table : WriteTable, event : SQL::TriggerEvent, before : Bool, old_rowid : Int64?,
                            old : Array(Value)?, new_rowid : Int64?, new : Array(Value)?, override : ConflictAction,
                            list_of_changed_names : Array(String)? = nil) : Nil
      return if @silent || @triggers_disabled
      list = table.list_of_triggers(@session)
      return if list.empty?
      fire_triggers(list, table.trigger_target, event, before, old_rowid, old, new_rowid, new, override, list_of_changed_names)
    end

    # sqlite3CodeRowTrigger: each trigger of *list* for *event* at this
    # time whose UPDATE OF columns the statement changes. With
    # recursive_triggers off, a trigger already running does not fire
    # again.
    def fire_triggers(list : Array(TriggerDefinition), target : TriggerTarget, event : SQL::TriggerEvent, before : Bool,
                      old_rowid : Int64?, old : Array(Value)?, new_rowid : Int64?, new : Array(Value)?,
                      override : ConflictAction, list_of_changed_names : Array(String)? = nil) : Nil
      list.each do |trigger|
        next unless trigger.event == event && trigger.before? == before && trigger.fires_for?(list_of_changed_names)
        next if !@session.recursive_triggers? && list_of_running_triggers.any?(&.same?(trigger))
        cache = @trigger_programs ||= TriggerProgramCache.new
        program = cache.program_for(@session, trigger, target, override)
        program.fire(self, old_rowid, old, new_rowid, new)
      end
    end

    # DROP TABLE deletes a parent table's rows with triggers off
    # (sqlite3FkDropTable sets disableTriggers).
    property? triggers_disabled = false

    # Whether *table* has a trigger for *event*, in a run that fires them.
    def triggers_for?(table : WriteTable, event : SQL::TriggerEvent) : Bool
      !@silent && !@triggers_disabled && table.has_triggers_for?(@session, event)
    end

    # Whether a trigger fires for *event* at this time on *table*.
    def triggers_fire?(table : WriteTable, event : SQL::TriggerEvent, before : Bool) : Bool
      return false if @silent || @triggers_disabled
      table.list_of_triggers(@session).any? { |trigger| trigger.event == event && trigger.before? == before }
    end

    # OP_Program: the trigger's changes count apart from the statement's,
    # and last_insert_rowid() and changes() come back when it ends.
    def enter_trigger(trigger : TriggerDefinition) : TriggerFrameState
      if @trigger_depth >= MAX_TRIGGER_DEPTH
        raise SQLError.new("too many levels of trigger recursion")
      end
      state = TriggerFrameState.new(@nested, @step_changes, @session.last_insert_rowid, @session.changes)
      @nested = 0
      @step_changes = 0_i64
      @trigger_depth += 1
      list_of_running_triggers << trigger
      state
    end

    def leave_trigger(state : TriggerFrameState) : Nil
      list_of_running_triggers.pop
      @trigger_depth -= 1
      @nested = state.nested
      @step_changes = state.step_changes
      @session.last_insert_rowid = state.last_insert_rowid
      @session.changes = state.changes
    end

    # OP_ResetCount after a trigger step.
    def finish_trigger_step : Nil
      @session.total_changes += @step_changes
      @session.changes = @step_changes
      @step_changes = 0_i64
    end

    # NEW of a BEFORE INSERT trigger: the row with its columns' affinity
    # (or STRICT check) and generated columns, and the rowid it will have
    # when one was given, else -1.
    def new_row_before_insert(table : WriteTable, row : Array(Value), explicit_rowid : Value) : {Int64?, Array(Value)}
      copy = row.dup
      rowid = nil.as(Int64?)
      alias_index = table.rowid_alias
      unless table.without_rowid?
        candidate = alias_index ? row[alias_index] : explicit_rowid
        rowid = candidate.nil? ? -1_i64 : WriteRun.must_be_int(candidate)
      end
      with_affinity(table, copy, rowid)
      {rowid, copy}
    end

    # The row's ordinary columns with their affinity, then its generated
    # columns.
    private def with_affinity(table : WriteTable, row : Array(Value), rowid : Int64?) : Nil
      if table.has_generated_columns?
        compute_generated(table, row, rowid)
      else
        definition = table.definition
        strict = definition.strict?
        definition.list_of_columns.each_with_index do |column, position|
          row[position] = if strict
                            StoredValue.for_strict_column(column.declared_type, column.column_name, row[position])
                          else
                            StoredValue.for_affinity(column.affinity, row[position])
                          end
        end
      end
      if (alias_index = table.rowid_alias) && rowid
        row[alias_index] = rowid
      end
    end

    # NEW of a BEFORE UPDATE trigger: the new values with affinity.
    def new_row_before_update(table : WriteTable, row : Array(Value), rowid : Int64?) : Array(Value)
      copy = row.dup
      with_affinity(table, copy, rowid)
      copy
    end
  end
end
