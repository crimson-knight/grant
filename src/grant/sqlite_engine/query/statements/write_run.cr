module Grant::SQLiteEngine::Query
  # A constraint failure with C's message and the conflict action that
  # decides what the failed statement keeps: ABORT undoes the statement,
  # FAIL keeps what it already changed, ROLLBACK ends the transaction.
  class ConstraintError < SQLError
    getter action : ConflictAction

    def initialize(message : String, @action : ConflictAction = ConflictAction::Abort)
      super(message, CONSTRAINT)
    end
  end

  # How an INSERT of one row ended.
  enum InsertResult
    Inserted
    Ignored
    Upserted
  end

  # The state of one write statement while it runs: the tables it writes
  # with their rules, the foreign key counter of its immediate constraints,
  # the rows it changed, and the AUTOINCREMENT values to record at its end.
  class WriteRun
    getter session : Session
    getter list_of_parameters : Array(Value)
    property changes = 0_i64
    # A single-row INSERT (not isMultiWrite): a missing parent of an
    # immediate foreign key fails the row before it is written.
    property? single_row = false
    # C would give the statement a statement journal (`StatementJournal`);
    # without one a runtime error keeps the rows already written.
    getter? statement_journal = true

    # Whether the statement is its own transaction (no BEGIN or SAVEPOINT
    # around it).
    property? autocommit = false

    # An autocommit statement without a statement journal images no pages
    # in its savepoint level: a failure rolls the whole transaction back
    # from the WAL or the rollback journal. Inside a transaction the level
    # keeps its images, so a failed statement is undone alone.
    def statement_journal=(value : Bool) : Bool
      @session.database.pager.skip_savepoint_images if autocommit? && !value
      @statement_journal = value
    end

    # Rows CREATE TABLE ... AS SELECT copies count nowhere.
    property? silent = false
    # FOREIGN KEY violations of immediate constraints still open in this
    # statement (Vdbe.nFkConstraint).
    property immediate_violations = 0_i64
    # True while an action (CASCADE, SET NULL) or REPLACE runs a nested
    # write: it changes no counters the statement reports.
    property nested = 0

    # AUTOINCREMENT: the largest rowid per table (memMax), written to
    # sqlite_sequence when the statement ends.
    # Made on first use: most statements touch no AUTOINCREMENT table.
    @autoincrement_maximum : Hash(String, Int64)?
    @list_of_autoincrement_tables : Array(WriteTable)?

    def initialize(@session : Session, @list_of_parameters : Array(Value))
    end

    # The main database; a table's own is `WriteTable#database`.
    def database : Database
      @session.database
    end

    def foreign_keys? : Bool
      @session.foreign_keys?
    end

    # The rules of *name*, raising "no such table" for a missing table.
    def table(name : String, schema : String? = nil) : WriteTable
      @session.write_table(name, schema) || raise SQLError.new("no such table: #{name}")
    end

    # --- INSERT -------------------------------------------------------------

    # Inserts *row* (declared column order; the rowid alias may hold the
    # rowid or NULL) into *table*. *explicit_rowid* is a rowid given by name
    # (`INSERT INTO t(rowid, ...)`) for a table without an alias. Returns the
    # outcome, the rowid and the row as stored.
    def insert_row(table : WriteTable, row : Array(Value), explicit_rowid : Value, override : ConflictAction,
                   upsert : UpsertPlan? = nil) : {InsertResult, Int64?, Array(Value)}
      if triggers_fire?(table, SQL::TriggerEvent::Insert, before: true)
        new_rowid, new = new_row_before_insert(table, row, explicit_rowid)
        fire_table_triggers(table, SQL::TriggerEvent::Insert, true, nil, nil, new_rowid, new, override)
      end
      rowid = nil.as(Int64?)
      unless table.without_rowid?
        alias_index = table.rowid_alias
        candidate = alias_index ? row[alias_index] : explicit_rowid
        if candidate.nil?
          rowid = new_rowid(table)
        else
          rowid = WriteRun.must_be_int(candidate)
        end
        row[alias_index] = rowid if alias_index
        # autoIncStep: the new rowid counts toward sqlite_sequence before
        # any constraint is checked, so an ignored row still moves it.
        note_autoincrement(table, rowid)
      end
      compute_generated(table, row, rowid)
      result = check_constraints(table, rowid, row, nil, override, upsert)
      return {result[0], result[1], result[2]} unless result[0].inserted?
      if replaced = result[3]
        delete_row(table, replaced[0], replaced[1], replace: true, override: ConflictAction::Replace)
      end
      if foreign_keys?
        child_added(table, row)
        parent_added(table, rowid, row)
      end
      entry_list = @session.take_index_entry_list
      begin
        table.database.write_row(table.layout, rowid, row, index_entries_into(entry_list, table, row, rowid))
      ensure
        @session.give_back_index_entry_list(entry_list)
      end
      if rowid && @nested == 0 && !@silent
        @session.last_insert_rowid = rowid
      end
      count_change
      unless @silent
        fire_table_triggers(table, SQL::TriggerEvent::Insert, false, nil, nil, rowid, row, override)
      end
      {InsertResult::Inserted, rowid, row}
    end

    # A row the statement changed counts in changes(); a row a trigger step
    # changed counts in total_changes() when the step ends (OP_ResetCount);
    # a row a foreign key action changed counts there at once, as the rows
    # of C's action programs do, even when the statement then fails.
    private def count_change : Nil
      return if @silent
      if @nested > 0
        @session.total_changes += 1
      elsif @trigger_depth > 0
        @step_changes += 1
      else
        @changes += 1
      end
    end

    # OP_MustBeInt for a rowid: integers stay, reals and text that hold an
    # integer exactly convert, anything else is "datatype mismatch".
    def self.must_be_int(value : Value) : Int64
      converted = ValueSemantics.apply_affinity(value, ExpressionAffinity::Integer)
      return converted if converted.is_a?(Int64)
      raise SQLError.new("datatype mismatch", SQLError::MISMATCH)
    end

    private def new_rowid(table : WriteTable) : Int64
      if table.definition.autoincrement?
        floor = autoincrement_maximum(table)
        rowid = table.database.next_rowid(table.layout, floor)
        return rowid
      end
      table.database.next_rowid(table.layout)
    end

    private def autoincrement_maximum(table : WriteTable) : Int64
      key = autoincrement_key(table)
      maximum = @autoincrement_maximum ||= {} of String => Int64
      if value = maximum[key]?
        return value
      end
      (@list_of_autoincrement_tables ||= [] of WriteTable) << table
      maximum[key] = table.database.sequence_of(table.name) || 0_i64
    end

    private def note_autoincrement(table : WriteTable, rowid : Int64) : Nil
      return unless table.definition.autoincrement?
      key = autoincrement_key(table)
      current = autoincrement_maximum(table)
      @autoincrement_maximum.try { |maximum| maximum[key] = rowid } if rowid > current
    end

    private def autoincrement_key(table : WriteTable) : String
      "#{@session.schema_name_of(table.database)}.#{table.name.downcase}"
    end

    # sqlite3AutoincrementBegin's tables, opened by any INSERT into them
    # (even one that inserts no row).
    def open_autoincrement(table : WriteTable) : Nil
      autoincrement_maximum(table) if table.definition.autoincrement?
    end

    # sqlite3AutoincrementEnd: each AUTOINCREMENT table's largest rowid goes
    # to sqlite_sequence when it passed the value stored there.
    def finish_autoincrement : Nil
      maximum = @autoincrement_maximum
      list_of_tables = @list_of_autoincrement_tables
      return unless maximum && list_of_tables
      list_of_tables.each do |table|
        value = maximum[autoincrement_key(table)]
        stored = table.database.sequence_of(table.name)
        next if stored && stored >= value
        table.database.write_sequence(table.name, value)
      end
    end

    # --- Constraint checks ----------------------------------------------

    # sqlite3GenerateConstraintChecks for a new row (*old_rowid* nil) or an
    # updated one. Applies the column affinities to *row* in place. Returns
    # the outcome (Inserted means "write it"), the rowid and row of an
    # upsert, and the row a REPLACE of the rowid must delete first.
    def check_constraints(table : WriteTable, rowid : Int64?, row : Array(Value), old : {Int64?, Array(Value)}?,
                          override : ConflictAction, upsert : UpsertPlan?) : {InsertResult, Int64?, Array(Value), {Int64?, Array(Value)}?}
      definition = table.definition
      # NOT NULL, in column order. REPLACE puts the DEFAULT in and the
      # column is checked again only after every other column (C's second
      # pass), so a later column's failure is the one reported.
      list_of_replaced = nil.as(Array(ColumnRule)?)
      recomputed = false
      table.list_of_columns_in_not_null_order.each do |column|
        # A DEFAULT that REPLACE put in may be read by generated columns:
        # they are computed again before their own NOT NULL is checked.
        if column.generated? && list_of_replaced && !recomputed
          compute_generated(table, row, rowid)
          recomputed = true
        end
        action = column.not_null
        next unless action
        next if column.position == table.rowid_alias
        next unless row[column.position].nil?
        action = override unless override.default?
        action = ConflictAction::Abort if action.default?
        if action.replace?
          if column.default_expression
            row[column.position] = default_value(table, column)
            (list_of_replaced ||= [] of ColumnRule) << column
            next
          end
          action = ConflictAction::Abort
        end
        return {InsertResult::Ignored, rowid, row, nil} if action.ignore?
        raise ConstraintError.new("NOT NULL constraint failed: #{table.name}.#{column.column_name}", action)
      end
      list_of_replaced.try &.each do |column|
        next unless row[column.position].nil?
        raise ConstraintError.new("NOT NULL constraint failed: #{table.name}.#{column.column_name}", ConflictAction::Abort)
      end
      compute_generated(table, row, rowid) if list_of_replaced && !recomputed
      database.store_values!(definition, row)
      if (alias_index = table.rowid_alias) && rowid
        row[alias_index] = rowid
      end
      # CHECK constraints, in declaration order.
      unless table.list_of_checks.empty?
        checks = check_programs(table)
        table.list_of_checks.each_with_index do |check, index|
          program = checks[index]
          program.list_of_pseudo_tables[0].row = row
          program.list_of_pseudo_tables[0].rowid = rowid
          value = program.evaluate(@list_of_parameters).try(&.[0]?)
          next if value.nil? || ValueSemantics.truth(value) != false
          action = override.default? ? ConflictAction::Abort : override
          return {InsertResult::Ignored, rowid, row, nil} if action.ignore?
          action = ConflictAction::Abort if action.replace?
          raise ConstraintError.new("CHECK constraint failed: #{check.constraint_name}", action)
        end
      end
      unique_override = override
      clause_for_all = nil.as(UpsertClause?)
      if upsert && (first = upsert.list_of_clauses.first?) && first.untargeted? && upsert.list_of_clauses.size == 1
        if first.do_update?
          unique_override = ConflictAction::Update
          clause_for_all = first
        else
          unique_override = ConflictAction::Ignore
          upsert = nil
        end
      end
      replace_row = nil.as({Int64?, Array(Value)}?)
      rowid_checked = false
      # The rowid, unless REPLACE on the rowid must wait for the indexes.
      rowid_action = ConflictAction::Default
      rowid_clause = nil.as(UpsertClause?)
      if rowid && !table.without_rowid?
        rowid_action = table.rowid_conflict
        rowid_action = unique_override unless unique_override.default?
        rowid_action = ConflictAction::Abort if rowid_action.default?
        if upsert && (clause = upsert.clause_for_rowid)
          rowid_clause = clause
          rowid_action = clause.do_update? ? ConflictAction::Update : ConflictAction::Ignore
        elsif clause_for_all
          rowid_clause = clause_for_all
        end
      end
      delay_rowid = rowid_action.replace? && rowid_action != unique_override && !table.list_of_indexes.empty?
      # An upsert whose first clause targets an index checks that index
      # before the rowid (upsertIpkDelay).
      if upsert && (first_clause = upsert.list_of_clauses.first?) && !first_clause.untargeted? && !first_clause.targets_rowid?
        delay_rowid = true
      end
      unless delay_rowid
        outcome = check_rowid(table, rowid, row, old, rowid_action, rowid_clause, upsert)
        return outcome if outcome
        rowid_checked = true
      end
      # nil stands for a WITHOUT ROWID table's PRIMARY KEY.
      ordered = table.list_of_rules_in_check_order
      if upsert
        targeted = upsert.list_of_clauses.compact_map(&.index_rule).uniq!.map(&.as(IndexRule?))
        targeted.unshift(nil) if table.without_rowid? && upsert.list_of_clauses.first?.try(&.targets_rowid?)
        ordered = targeted + ordered.reject { |rule| targeted.includes?(rule) }
      end
      ordered.each do |rule|
        unless rule
          outcome = check_primary_key(table, row, old, unique_override, upsert, clause_for_all)
          return outcome if outcome
          next
        end
        next unless rule.unique?
        index = rule.layout
        next unless index_includes?(table, index, row, rowid)
        entry = index_entry(table, index, row, rowid)
        existing = table.database.index_entry_matching(index, entry)
        next unless existing
        existing_key = existing_key_of(table, index, existing)
        next if old && same_row?(table, existing_key, old)
        action = rule.conflict
        action = unique_override unless unique_override.default?
        action = ConflictAction::Abort if action.default?
        clause = upsert.try(&.clause_for(rule)) || clause_for_all
        if clause && upsert
          action = clause.do_update? ? ConflictAction::Update : ConflictAction::Ignore
        end
        case action
        when .ignore?
          return {InsertResult::Ignored, rowid, row, nil}
        when .update?
          target = existing_row(table, existing_key) || raise CorruptDatabase.new("index #{index.entry.object_name} names a missing row of #{table.name}")
          return upsert_update(table, target, row, clause || raise Error.new("upsert without a clause"))
        when .replace?
          victim = existing_row(table, existing_key)
          if victim
            delete_row(table, victim[0], victim[1], replace: true, override: ConflictAction::Replace)
          end
        else
          raise ConstraintError.new(unique_message(rule), action)
        end
      end
      unless rowid_checked
        outcome = check_rowid(table, rowid, row, old, rowid_action, rowid_clause, upsert)
        return outcome if outcome
      end
      if rowid && !table.without_rowid? && rowid_action.replace? && !(old && old[0] == rowid)
        if victim = table.database.row_at(table.layout, rowid)
          replace_row = {rowid.as(Int64?), victim}
        end
      end
      {InsertResult::Inserted, rowid, row, replace_row}
    end

    # The rowid uniqueness check (nil when it passes or REPLACE resolves it).
    private def check_rowid(table : WriteTable, rowid : Int64?, row : Array(Value), old : {Int64?, Array(Value)}?,
                            action : ConflictAction, clause : UpsertClause?,
                            upsert : UpsertPlan?) : {InsertResult, Int64?, Array(Value), {Int64?, Array(Value)}?}?
      return if rowid.nil? || table.without_rowid?
      return if old && old[0] == rowid
      return unless table.database.row_exists?(table.layout, rowid)
      case action
      when .ignore?
        {InsertResult::Ignored, rowid, row, nil}
      when .update?
        target = table.database.row_at(table.layout, rowid) || return
        upsert_update(table, {rowid.as(Int64?), target}, row, clause || raise Error.new("upsert without a clause"))
      when .replace?
        nil
      else
        column = table.rowid_alias.try { |index| table.list_of_columns[index].column_name } || "rowid"
        raise ConstraintError.new("UNIQUE constraint failed: #{table.name}.#{column}", action)
      end
    end

    # The PRIMARY KEY of a WITHOUT ROWID table (nil when it passes or
    # REPLACE resolved it): the table's own b-tree holds the key.
    private def check_primary_key(table : WriteTable, row : Array(Value), old : {Int64?, Array(Value)}?,
                                  unique_override : ConflictAction, upsert : UpsertPlan?,
                                  clause_for_all : UpsertClause?) : {InsertResult, Int64?, Array(Value), {Int64?, Array(Value)}?}?
      existing = table.database.row_with_key_of(table.layout, row) || return
      positions = table.layout.list_of_primary_key_positions
      key = positions.map { |position| existing[position] }
      return if old && same_row?(table, key, old)
      action = table.primary_key_conflict
      action = unique_override unless unique_override.default?
      action = ConflictAction::Abort if action.default?
      clause = upsert.try(&.clause_for_rowid) || clause_for_all
      if clause && upsert
        action = clause.do_update? ? ConflictAction::Update : ConflictAction::Ignore
      end
      case action
      when .ignore?
        {InsertResult::Ignored, nil.as(Int64?), row, nil}
      when .update?
        upsert_update(table, {nil.as(Int64?), existing}, row, clause || raise Error.new("upsert without a clause"))
      when .replace?
        delete_row(table, nil, existing, replace: true, override: ConflictAction::Replace)
        nil
      else
        columns = positions.map { |position| "#{table.name}.#{table.list_of_columns[position].column_name}" }
        raise ConstraintError.new("UNIQUE constraint failed: #{columns.join(", ")}", action)
      end
    end

    # C names the columns, or for an index with an expression term the
    # index (sqlite3UniqueConstraint).
    def unique_message(rule : IndexRule) : String
      if rule.layout.has_expressions?
        return "UNIQUE constraint failed: index '#{rule.layout.entry.object_name}'"
      end
      "UNIQUE constraint failed: #{rule.columns_text}"
    end

    # The rowid (or WITHOUT ROWID key) an index entry points at.
    private def existing_key_of(table : WriteTable, index : IndexLayout, existing : Array(Value)) : Int64 | Array(Value)
      if table.without_rowid?
        positions = table.layout.list_of_primary_key_positions
        row = Array(Value).new(table.list_of_columns.size, nil)
        index.list_of_key_positions.each_with_index { |position, offset| row[position] = existing[offset] }
        index.list_of_tail_positions.each_with_index { |position, offset| row[position] = existing[index.key_count + offset] }
        positions.map { |position| row[position].as(Value) }
      else
        value = existing.last
        value.is_a?(Int64) ? value : raise CorruptDatabase.new("index #{index.entry.object_name} entry without a rowid")
      end
    end

    private def same_row?(table : WriteTable, key : Int64 | Array(Value), old : {Int64?, Array(Value)}) : Bool
      if key.is_a?(Int64)
        old[0] == key
      else
        positions = table.layout.list_of_primary_key_positions
        old_key = positions.map { |position| old[1][position] }
        key.zip(old_key).all? { |left, right| ValueSemantics.compare(left, right) == 0 }
      end
    end

    private def existing_row(table : WriteTable, key : Int64 | Array(Value)) : {Int64?, Array(Value)}?
      if key.is_a?(Int64)
        found = table.database.row_at(table.layout, key)
        found ? {key.as(Int64?), found} : nil
      else
        probe = Array(Value).new(table.list_of_columns.size, nil)
        table.layout.list_of_primary_key_positions.each_with_index { |position, offset| probe[position] = key[offset] }
        found = table.database.row_with_key_of(table.layout, probe)
        found ? {nil.as(Int64?), found} : nil
      end
    end

    # The entry of *index* for the row: the key terms (expression terms
    # evaluated over the row, sqlite3ExprCodeLoadIndexColumn) and the rowid
    # or primary key.
    #
    # With *key*, the entry is written into that array instead of a new one.
    def index_entry(table : WriteTable, index : IndexLayout, row : Array(Value), rowid : Int64?, key : Array(Value)? = nil) : Array(Value)
      unless index.has_expressions?
        return key ? index.fill_entry(key, row, rowid) : index.entry_for(row, rowid)
      end
      rule = table.list_of_indexes.find(&.layout.same?(index)) ||
             table.list_of_indexes.find { |candidate| candidate.layout.entry.object_name == index.entry.object_name } ||
             raise Error.new("index #{index.entry.object_name} is not an index of #{table.name}")
      program = key_expression_program(table, rule)
      pseudo = program.list_of_pseudo_tables[0]
      pseudo.row = row
      pseudo.rowid = rowid
      values = program.evaluate(@list_of_parameters) || raise Error.new("index #{index.entry.object_name} expressions gave no row")
      key ? index.fill_entry(key, row, rowid, values) : index.entry_for(row, rowid, values)
    end

    # Compiles the expression terms of *rule*, raising what C's
    # sqlite3ResolveSelfReference reports for them and for a partial
    # index's WHERE.
    def check_index_expressions(table : WriteTable, rule : IndexRule) : Nil
      rule.list_of_key_expressions.each { |expression| refuse_in_index(expression, "index expressions") }
      rule.where.try { |where| refuse_in_index(where, "partial index WHERE clauses") }
      return if rule.list_of_key_expressions.empty?
      key_expression_program(table, rule)
    end

    # Functions without SQLITE_FUNC_CONSTANT, which an index may not call.
    INDEX_PROHIBITED_FUNCTIONS = ExpressionWalk::NONDETERMINISTIC +
                                 %w[sqlite_version sqlite_source_id sqlite_compileoption_get sqlite_compileoption_used]

    # resolve.c notValidImpl under NC_IdxExpr and NC_PartIdx: a subquery, a
    # bound parameter or a non-deterministic function fails CREATE INDEX
    # (the first met, walking the expression before its operands).
    private def refuse_in_index(expression : SQL::Expression, context : String) : Nil
      if expression.is_a?(SQL::ScalarSubquery) || expression.is_a?(SQL::Exists) || expression.is_a?(SQL::InSelect)
        raise SQLError.new("subqueries prohibited in #{context}")
      end
      raise SQLError.new("parameters prohibited in #{context}") if expression.is_a?(SQL::Parameter)
      if expression.is_a?(SQL::FunctionCall) && INDEX_PROHIBITED_FUNCTIONS.includes?(expression.name.value.downcase)
        raise SQLError.new("non-deterministic functions prohibited in #{context}")
      end
      index_compiler.children_of(expression).each { |child| refuse_in_index(child, context) }
    end

    private getter index_compiler : Compiler { Compiler.new(@session) }

    private def key_expression_program(table : WriteTable, rule : IndexRule) : RowProgram
      table.key_expression_programs[rule.layout.entry.object_name] ||= begin
        pseudo = PseudoTable.new(table.name, table.table_info)
        RowProgram.new(@session, RowProgram.columns(rule.list_of_key_expressions), [pseudo], deterministic_context: "an index")
      end
    end

    # The index entries an UPDATE that keeps *rowid* removes and adds. When
    # every index lacks a WHERE and expression terms and its columns hold
    # the same values in both rows, every entry stays and no key is built;
    # otherwise the entries of both rows are built and compared.
    private def moved_index_entries(table : WriteTable, old_row : Array(Value), new_row : Array(Value),
                                    rowid : Int64) : {Array({IndexLayout, Array(Value)}), Array({IndexLayout, Array(Value)})}
      if table.list_of_index_layouts.all? { |index| !index.needs_evaluation? && same_columns?(index, old_row, new_row) }
        return {[] of {IndexLayout, Array(Value)}, [] of {IndexLayout, Array(Value)}}
      end
      old_entries = index_entries(table, old_row, rowid)
      new_entries = index_entries(table, new_row, rowid)
      {WriteRun.entries_not_in(old_entries, new_entries), WriteRun.entries_not_in(new_entries, old_entries)}
    end

    # Whether *old_row* and *new_row* hold the same values (as same_key?
    # compares them) in every column the entries of *index* hold.
    private def same_columns?(index : IndexLayout, old_row : Array(Value), new_row : Array(Value)) : Bool
      index.list_of_key_positions.all? { |position| WriteRun.same_value?(old_row[position], new_row[position]) } &&
        index.list_of_tail_positions.all? { |position| WriteRun.same_value?(old_row[position], new_row[position]) }
    end

    # The entries of *list* that *other* does not hold with the same key
    # (each value the same storage class and value).
    def self.entries_not_in(list : Array({IndexLayout, Array(Value)}), other : Array({IndexLayout, Array(Value)})) : Array({IndexLayout, Array(Value)})
      list.reject do |(index, key)|
        other.any? { |(other_index, other_key)| other_index.same?(index) && WriteRun.same_key?(key, other_key) }
      end
    end

    def self.same_key?(left : Array(Value), right : Array(Value)) : Bool
      return false unless left.size == right.size
      left.each_with_index do |value, position|
        return false unless same_value?(value, right[position])
      end
      true
    end

    def self.same_value?(value : Value, other : Value) : Bool
      return false unless value.class == other.class && value == other
      # -0.0 equals 0.0 but is stored with its own bits.
      !(value.is_a?(Float64) && other.is_a?(Float64) && value.unsafe_as(UInt64) != other.unsafe_as(UInt64))
    end

    # `index_entries`, built in *entry_list*: its arrays from the row before
    # are refilled, so a row written at once allocates no entries.
    def index_entries_into(entry_list : IndexEntryList, table : WriteTable, row : Array(Value), rowid : Int64?) : Array({IndexLayout, Array(Value)})
      entry_list.start
      table.list_of_index_layouts.each do |index|
        next unless index_includes?(table, index, row, rowid)
        entry_list.add(index, index_entry(table, index, row, rowid, entry_list.spare_key))
      end
      entry_list.list_of_entries
    end

    # Each index of *table* that holds the row, with the row's entry.
    def index_entries(table : WriteTable, row : Array(Value), rowid : Int64?) : Array({IndexLayout, Array(Value)})
      table.list_of_index_layouts.compact_map do |index|
        next unless index_includes?(table, index, row, rowid)
        {index, index_entry(table, index, row, rowid)}
      end
    end

    # Whether a partial index holds the row (its WHERE is true).
    def index_includes?(table : WriteTable, index : IndexLayout, row : Array(Value), rowid : Int64?) : Bool
      rule = table.list_of_indexes.find(&.layout.same?(index))
      where = rule.try(&.where)
      return true unless where
      program = table.partial_programs[index.entry.object_name] ||= begin
        pseudo = PseudoTable.new(table.name, table.table_info)
        RowProgram.new(@session, RowProgram.columns([where] of SQL::Expression), [pseudo], deterministic_context: "an index")
      end
      pseudo = program.list_of_pseudo_tables[0]
      pseudo.row = row
      pseudo.rowid = rowid
      ValueSemantics.truth(program.evaluate(@list_of_parameters).try(&.[0]?)) == true
    end

    private def check_programs(table : WriteTable) : Array(RowProgram)
      table.check_programs ||= table.list_of_checks.map do |check|
        pseudo = PseudoTable.new(table.name, table.table_info)
        RowProgram.new(@session, RowProgram.columns([check.expression] of SQL::Expression), [pseudo],
          deterministic_context: "a CHECK constraint")
      end
    end

    # The DEFAULT of *column*, evaluated (NULL without one).
    def default_value(table : WriteTable, column : ColumnRule) : Value
      expression = column.default_expression
      return unless expression
      program = table.default_programs[column.position] ||= RowProgram.new(@session, RowProgram.columns([expression] of SQL::Expression),
        [] of PseudoTable)
      program.evaluate([] of Value).try(&.[0]?)
    end

    # --- Upsert -------------------------------------------------------------

    # sqlite3UpsertDoUpdate: the conflicting row *target* takes the DO
    # UPDATE assignments, with `excluded` holding the row that was refused.
    private def upsert_update(table : WriteTable, target : {Int64?, Array(Value)}, proposed : Array(Value),
                              clause : UpsertClause) : {InsertResult, Int64?, Array(Value), {Int64?, Array(Value)}?}
      program = clause.program(self, table)
      existing_pseudo, excluded_pseudo = program.list_of_pseudo_tables
      existing_pseudo.row = target[1]
      existing_pseudo.rowid = target[0]
      excluded_pseudo.row = proposed
      excluded_pseudo.rowid = target[0]
      values = program.evaluate(@list_of_parameters)
      return {InsertResult::Ignored, target[0], target[1], nil} unless values
      new_row = target[1].dup
      explicit_rowid = nil.as(Value)
      clause.list_of_positions.each_with_index do |position, index|
        if position < 0
          explicit_rowid = values[index]
        else
          new_row[position] = values[index]
        end
      end
      updated = update_row(table, target[0], target[1], new_row, explicit_rowid, ConflictAction::Abort, clause.list_of_positions)
      return {InsertResult::Ignored, target[0], target[1], nil} unless updated
      {InsertResult::Upserted, updated[0], updated[1], nil}
    end

    # --- UPDATE -------------------------------------------------------------

    # Replaces the row *old_row* at *old_rowid* by *new_row* (declared order,
    # before affinity). *explicit_rowid* is a new rowid set by name.
    # *list_of_changed* holds the positions the statement assigned (-1 for
    # the rowid). Returns the rowid and the row as stored, or nil for a row
    # an IGNORE conflict skipped.
    #
    # *list_of_changed_names* are the SET list's names as written, which
    # UPDATE OF triggers match; by default the names of *list_of_changed*.
    def update_row(table : WriteTable, old_rowid : Int64?, old_row : Array(Value), new_row : Array(Value),
                   explicit_rowid : Value, override : ConflictAction, list_of_changed : Array(Int32),
                   list_of_changed_names : Array(String)? = nil) : {Int64?, Array(Value)}?
      rowid = old_rowid
      unless table.without_rowid?
        if alias_index = table.rowid_alias
          if list_of_changed.includes?(alias_index)
            # OP_MustBeInt: an UPDATE that sets the INTEGER PRIMARY KEY to
            # NULL is "datatype mismatch".
            rowid = WriteRun.must_be_int(new_row[alias_index])
          end
          new_row[alias_index] = rowid
        elsif list_of_changed.includes?(-1)
          rowid = WriteRun.must_be_int(explicit_rowid)
        end
      end
      fill_virtual_columns(table, old_row, old_rowid)
      compute_generated(table, new_row, rowid)
      original_old_row = old_row
      names = nil.as(Array(String)?)
      if triggers_for?(table, SQL::TriggerEvent::Update)
        names = list_of_changed_names || WriteRun.changed_names(table, list_of_changed)
        if triggers_fire?(table, SQL::TriggerEvent::Update, before: true)
          fire_table_triggers(table, SQL::TriggerEvent::Update, true, old_rowid, old_row, rowid,
            new_row_before_update(table, new_row, rowid), override, names)
          current = reloaded_after_before_triggers(table, old_rowid, old_row, new_row, rowid, list_of_changed)
          return unless current
          old_row = current
        end
      end
      result = check_constraints(table, rowid, new_row, {old_rowid, old_row}, override, nil)
      return if result[0].ignored?
      if foreign_keys?
        child_removed(table, old_row, new_row, list_of_changed)
        parent_removed(table, old_rowid, old_row, new_row, list_of_changed)
      end
      if rowid && rowid == old_rowid && result[3].nil?
        # The row keeps its rowid: its cell is overwritten in place, and only
        # the index entries whose keys changed move (C leaves an index whose
        # columns the UPDATE does not change alone).
        removed, added = moved_index_entries(table, old_row, new_row, rowid)
        table.database.remove_index_entries(table.layout, removed)
        table.database.write_row(table.layout, rowid, new_row, added)
      else
        old_entries = index_entries(table, old_row, old_rowid)
        new_entries = index_entries(table, new_row, rowid)
        table.database.remove_row(table.layout, old_rowid, old_row, old_entries)
        if replaced = result[3]
          delete_row(table, replaced[0], replaced[1], replace: true, override: ConflictAction::Replace)
        end
        table.database.write_row(table.layout, rowid, new_row, new_entries)
      end
      if foreign_keys?
        child_added(table, new_row, old_row, list_of_changed)
        parent_added(table, rowid, new_row, old_row, list_of_changed)
        parent_actions(table, old_row, new_row, list_of_changed)
      end
      count_change
      if names
        fire_table_triggers(table, SQL::TriggerEvent::Update, false, old_rowid, original_old_row, rowid, new_row, override, names)
      end
      {rowid, new_row}
    end

    # The column names of the positions an UPDATE changes (-1: the rowid).
    def self.changed_names(table : WriteTable, list_of_changed : Array(Int32)) : Array(String)
      list_of_changed.map { |position| position < 0 ? "rowid" : table.list_of_columns[position].column_name }
    end

    # After BEFORE UPDATE triggers C finds the row again: gone, the row is
    # skipped (nil); otherwise the columns the statement does not set take
    # the values the triggers left. Returns the row as it now is.
    private def reloaded_after_before_triggers(table : WriteTable, old_rowid : Int64?, old_row : Array(Value),
                                               new_row : Array(Value), rowid : Int64?,
                                               list_of_changed : Array(Int32)) : Array(Value)?
      current = refreshed(table, old_rowid, old_row)
      return unless current
      fill_virtual_columns(table, current, old_rowid)
      table.list_of_columns.each do |column|
        position = column.position
        next if position == table.rowid_alias || list_of_changed.includes?(position)
        new_row[position] = current[position]
      end
      compute_generated(table, new_row, rowid)
      current
    end

    # --- DELETE -------------------------------------------------------------

    # Deletes the row with its index entries, with foreign key processing.
    # *replace* marks a delete REPLACE makes (not counted in changes()).
    # DELETE triggers fire, except for a REPLACE with recursive_triggers
    # off; *override* is the conflict policy their programs take.
    def delete_row(table : WriteTable, rowid : Int64?, row : Array(Value), replace : Bool = false,
                   override : ConflictAction = ConflictAction::Default) : Nil
      fill_virtual_columns(table, row, rowid)
      original_row = row
      fires = (!replace || @session.recursive_triggers?) && triggers_for?(table, SQL::TriggerEvent::Delete)
      if fires && triggers_fire?(table, SQL::TriggerEvent::Delete, before: true)
        fire_table_triggers(table, SQL::TriggerEvent::Delete, true, rowid, row, nil, nil, override)
        # A BEFORE trigger that deleted the row leaves nothing to delete.
        current = refreshed(table, rowid, row)
        return unless current
        fill_virtual_columns(table, current, rowid)
        row = current
      end
      if foreign_keys?
        child_removed(table, row)
        parent_removed(table, rowid, row)
      end
      table.database.remove_row(table.layout, rowid, row, index_entries(table, row, rowid))
      parent_actions(table, row, nil) if foreign_keys?
      count_change unless replace
      fire_table_triggers(table, SQL::TriggerEvent::Delete, false, rowid, original_row, nil, nil, override) if fires
    end

    # --- Foreign keys -------------------------------------------------------

    private def count_violation(rule : ForeignKeyRule, amount : Int64) : Nil
      if rule.deferred? || @session.defer_foreign_keys?
        @session.deferred_violations += amount
      else
        @immediate_violations += amount
      end
    end

    # fkChildIsModified / fkParentIsModified for an UPDATE.
    private def touches?(positions : Array(Int32), list_of_changed : Array(Int32)?, table : WriteTable) : Bool
      return true unless list_of_changed
      positions.any? { |position| list_of_changed.includes?(position) || (position == table.rowid_alias && list_of_changed.includes?(-1)) }
    end

    # A child row was added: a missing parent is a violation.
    private def child_added(table : WriteTable, row : Array(Value), old_row : Array(Value)? = nil,
                            list_of_changed : Array(Int32)? = nil) : Nil
      table.list_of_foreign_keys.each do |rule|
        next unless touches?(rule.list_of_child_positions, list_of_changed, table) || same_table?(rule.parent_table, table.name)
        lookup = parent_lookup(rule)
        next unless lookup
        values = rule.list_of_child_positions.map { |position| row[position].as(Value) }
        next if values.any?(Nil)
        next if lookup.self_reference?(row, values)
        next if lookup.parent_exists?(values)
        if @single_row && @nested == 0 && !rule.deferred? && !@session.defer_foreign_keys? && old_row.nil?
          raise ConstraintError.new("FOREIGN KEY constraint failed")
        end
        count_violation(rule, 1)
      end
    end

    # A child row was removed: if it had no parent, a violation ends.
    private def child_removed(table : WriteTable, row : Array(Value), new_row : Array(Value)? = nil,
                              list_of_changed : Array(Int32)? = nil) : Nil
      table.list_of_foreign_keys.each do |rule|
        next unless touches?(rule.list_of_child_positions, list_of_changed, table) || same_table?(rule.parent_table, table.name)
        lookup = parent_lookup(rule)
        next unless lookup
        values = rule.list_of_child_positions.map { |position| row[position].as(Value) }
        next if values.any?(Nil)
        count_violation(rule, -1) unless lookup.parent_exists?(values)
      end
    end

    # A parent row was added: children waiting for it are no longer
    # violations.
    private def parent_added(table : WriteTable, rowid : Int64?, row : Array(Value), old_row : Array(Value)? = nil,
                             list_of_changed : Array(Int32)? = nil) : Nil
      referencing(table).each do |child_table, rule, parent_positions|
        next unless touches?(parent_positions, list_of_changed, table)
        next if old_row.nil? && !rule.deferred? && !@session.defer_foreign_keys? && @immediate_violations == 0
        key = parent_positions.map { |position| (position == table.rowid_alias ? rowid : row[position]).as(Value) }
        next if key.any?(Nil)
        count = matching_children(child_table, rule, table, parent_positions, key).size
        count_violation(rule, -count.to_i64) if count > 0
      end
    end

    # A parent row was removed: its children become violations until an
    # action resolves them.
    private def parent_removed(table : WriteTable, rowid : Int64?, row : Array(Value), new_row : Array(Value)? = nil,
                               list_of_changed : Array(Int32)? = nil) : Nil
      referencing(table).each do |child_table, rule, parent_positions|
        next unless touches?(parent_positions, list_of_changed, table)
        key = parent_positions.map { |position| (position == table.rowid_alias ? rowid : row[position]).as(Value) }
        next if key.any?(Nil)
        count = matching_children(child_table, rule, table, parent_positions, key).size
        count_violation(rule, count.to_i64) if count > 0
      end
    end

    # The ON DELETE / ON UPDATE actions (sqlite3FkActions), after the
    # parent row changed.
    private def parent_actions(table : WriteTable, old_row : Array(Value), new_row : Array(Value)?,
                               list_of_changed : Array(Int32)? = nil) : Nil
      referencing(table).each do |child_table, rule, parent_positions|
        next unless touches?(parent_positions, list_of_changed, table)
        action = new_row ? rule.on_update : rule.on_delete
        next if action == "NO ACTION"
        key = parent_positions.map { |position| old_row[position].as(Value) }
        next if key.any?(Nil)
        if changed_row = new_row
          new_key = parent_positions.map { |position| changed_row[position].as(Value) }
          next if key.zip(new_key).all? { |left, right| ValueSemantics.compare(left, right) == 0 && left.class == right.class }
        end
        children = matching_children(child_table, rule, table, parent_positions, key)
        next if children.empty?
        if action == "RESTRICT"
          raise ConstraintError.new("FOREIGN KEY constraint failed")
        end
        @nested += 1
        begin
          children.each do |child_rowid, child_row|
            current = refreshed(child_table, child_rowid, child_row)
            next unless current
            case action
            when "CASCADE"
              if changed_row = new_row
                updated = current.dup
                rule.list_of_child_positions.each_with_index do |position, offset|
                  updated[position] = changed_row[parent_positions[offset]]
                end
                update_row(child_table, child_rowid, current, updated, nil, ConflictAction::Abort, rule.list_of_child_positions)
              else
                delete_row(child_table, child_rowid, current, override: ConflictAction::Abort)
              end
            when "SET NULL", "SET DEFAULT"
              updated = current.dup
              rule.list_of_child_positions.each do |position|
                updated[position] = action == "SET NULL" ? nil : default_value(child_table, child_table.list_of_columns[position])
              end
              update_row(child_table, child_rowid, current, updated, nil, ConflictAction::Abort, rule.list_of_child_positions)
            end
          end
        ensure
          @nested -= 1
        end
      end
    end

    private def refreshed(table : WriteTable, rowid : Int64?, row : Array(Value)) : Array(Value)?
      return table.database.row_at(table.layout, rowid) if rowid
      table.database.row_with_key_of(table.layout, row)
    end

    private def same_table?(left : String, right : String) : Bool
      left.compare(right, case_insensitive: true) == 0
    end

    # The foreign keys of every table that name *table* as parent, with the
    # parent key positions each refers to, newest first: C links each new
    # foreign key at the head of its parent's list (sqlite3CreateForeignKey,
    # fkeyHash), so sqlite3FkActions runs a later table's CASCADE before an
    # earlier table's RESTRICT stops the statement.
    private def referencing(table : WriteTable) : Array({WriteTable, ForeignKeyRule, Array(Int32)})
      list = [] of {WriteTable, ForeignKeyRule, Array(Int32)}
      list_of_children = @session.list_of_child_tables(table.name)
      return list if list_of_children.empty?
      list_of_children.each do |child_name|
        child = table(child_name)
        child.list_of_foreign_keys.each do |rule|
          next unless same_table?(rule.parent_table, table.name)
          lookup = parent_lookup(rule)
          next unless lookup
          list << {child, rule, lookup.list_of_parent_positions}
        end
      end
      list.reverse!
    end

    # The child rows whose key equals *key*, compared as fkScanChildren
    # does: the parent column's affinity and collation.
    private def matching_children(child : WriteTable, rule : ForeignKeyRule, parent : WriteTable,
                                  parent_positions : Array(Int32), key : Array(Value)) : Array({Int64?, Array(Value)})
      found = [] of {Int64?, Array(Value)}
      parent_info = parent.table_info
      affinities = parent_positions.map { |position| parent_info.list_of_affinities[position] }
      collations = parent_positions.map { |position| parent_info.list_of_collations[position] }
      child_info = child.table_info
      cursor_rows(child) do |rowid, row|
        matched = rule.list_of_child_positions.each_with_index.all? do |position, offset|
          value = row[position]
          next false if value.nil?
          child_affinity = child_info.list_of_affinities[position]
          affinity = ValueSemantics.comparison_affinity(affinities[offset], child_affinity)
          either_text = value.is_a?(String) || key[offset].is_a?(String)
          left = ValueSemantics.prepare_for_comparison(key[offset], affinity, either_text)
          right = ValueSemantics.prepare_for_comparison(value, affinity, either_text)
          ValueSemantics.compare(left, right, collations[offset]) == 0
        end
        found << {rowid, row} if matched
      end
      found
    end

    # Every row of a table (rowid, declared-order values).
    def cursor_rows(table : WriteTable, & : Int64?, Array(Value) ->) : Nil
      info = table.table_info
      if info.without_rowid?
        cursor = IndexCursor.new(info.database, info.root_page, IndexOrder.new([] of Collation, [] of Bool))
        moved = cursor.first
        while moved
          row = info.row_from(nil, cursor.record)
          fill_virtual_columns(table, row, nil)
          yield nil, row
          moved = cursor.advance
        end
      else
        cursor = TableCursor.new(info.database, info.root_page)
        moved = cursor.first
        while moved
          rowid = cursor.rowid
          row = info.row_from(rowid, cursor.record)
          fill_virtual_columns(table, row, rowid)
          yield rowid, row
          moved = cursor.advance
        end
      end
    end

    # Made on first use: most statements check no foreign key.
    @parent_lookups : Hash(ForeignKeyRule, ParentLookup?)?

    # How to find a foreign key's parent row; raises C's errors for a
    # missing parent table and for parent columns without a UNIQUE index.
    private def parent_lookup(rule : ForeignKeyRule) : ParentLookup?
      lookups = @parent_lookups ||= {} of ForeignKeyRule => ParentLookup?
      return lookups[rule] if lookups.has_key?(rule)
      parent_info = @session.table(rule.parent_table)
      raise SQLError.new("no such table: main.#{rule.parent_table}") unless parent_info
      parent = table(rule.parent_table)
      lookups[rule] = ParentLookup.locate(self, rule, parent)
    end
  end

  # sqlite3FkLocateIndex and fkLookupParent: the parent key of a foreign
  # key (its INTEGER PRIMARY KEY, or a UNIQUE index whose columns and
  # collations equal the key's) and the search for a parent row.
  class ParentLookup
    getter list_of_parent_positions : Array(Int32)

    def initialize(@run : WriteRun, @rule : ForeignKeyRule, @parent : WriteTable, @list_of_parent_positions : Array(Int32),
                   @index : IndexLayout?)
    end

    def self.locate(run : WriteRun, rule : ForeignKeyRule, parent : WriteTable) : ParentLookup
      info = parent.table_info
      mismatch = SQLError.new(%(foreign key mismatch - "#{rule.child_table}" referencing "#{info.name}"))
      names = rule.list_of_parent_columns
      if names.nil?
        if alias_index = info.rowid_alias
          raise mismatch unless rule.list_of_child_positions.size == 1
          return new(run, rule, parent, [alias_index], nil)
        end
        key = info.definition.list_of_primary_key_columns
        raise mismatch if key.empty? || key.size != rule.list_of_child_positions.size
        names = key
      end
      raise mismatch unless names.size == rule.list_of_child_positions.size
      positions = names.map { |name| info.column_index(name) || raise mismatch }
      if positions.size == 1 && positions[0] == info.rowid_alias
        return new(run, rule, parent, positions, nil)
      end
      index = info.list_of_indexes.find do |candidate|
        candidate.unique? && candidate.entry.sql.try { |sql| SQL::Parser.parse_schema(sql).as?(SQL::CreateIndex).try(&.where) }.nil? &&
          candidate.list_of_key_positions.size == positions.size &&
          positions.all? { |position| candidate.list_of_key_positions.includes?(position) } &&
          candidate.list_of_key_positions.each_with_index.all? do |position, offset|
            candidate.comparator.list_of_key_columns[offset].collation == info.list_of_collations[position]
          end
      end
      raise mismatch unless index
      ordered = index.list_of_key_positions
      new(run, rule, parent, ordered, index)
    end

    # Child values (in the rule's order) mapped to the parent key order.
    private def key_values(values : Array(Value)) : Array(Value)
      info = @parent.table_info
      declared = @rule.list_of_parent_columns
      @list_of_parent_positions.map do |position|
        offset = if declared
                   declared.index { |name| info.column_index(name) == position } || 0
                 elsif @index
                   info.definition.list_of_primary_key_columns.index { |name| info.column_index(name) == position } || 0
                 else
                   0
                 end
        ValueSemantics.apply_record_affinity(values[offset], info.list_of_affinities[position])
      end
    end

    def parent_exists?(values : Array(Value)) : Bool
      database = @parent.database
      if index = @index
        key = key_values(values)
        probe = Array(Value).new(@parent.list_of_columns.size, nil)
        @list_of_parent_positions.each_with_index { |position, offset| probe[position] = key[offset] }
        entry = index.entry_for(probe, 0_i64)
        !database.index_entry_matching(index, entry).nil?
      else
        value = ValueSemantics.apply_affinity(values[0], ExpressionAffinity::Integer)
        return false unless value.is_a?(Int64)
        database.row_exists?(@parent.layout, value)
      end
    end

    # fkLookupParent's self-reference rule: a row that is its own parent.
    def self_reference?(row : Array(Value), values : Array(Value)) : Bool
      return false unless @rule.parent_table.compare(@rule.child_table, case_insensitive: true) == 0
      key = key_values(values)
      @list_of_parent_positions.each_with_index.all? do |position, offset|
        ValueSemantics.compare(row[position], key[offset]) == 0
      end
    end
  end

  # The index entries of the row being written, kept from row to row: each
  # entry array is refilled for the next row once the last one is written.
  class IndexEntryList
    getter list_of_entries = [] of {IndexLayout, Array(Value)}
    @list_of_spare_keys = [] of Array(Value)

    # Empties the list for the next row, keeping its arrays.
    def start : Nil
      @list_of_entries.each { |(_, key)| @list_of_spare_keys << key }
      @list_of_entries.clear
    end

    # An array to write the next entry into.
    def spare_key : Array(Value)
      @list_of_spare_keys.pop? || [] of Value
    end

    def add(index : IndexLayout, key : Array(Value)) : Nil
      @list_of_entries << {index, key}
    end
  end

  class Session
    @spare_index_entry_list : IndexEntryList? = nil

    # The list a row's index entries are built in. A row written while
    # another is (a trigger, a foreign key action) gets a list of its own.
    def take_index_entry_list : IndexEntryList
      list = @spare_index_entry_list
      return IndexEntryList.new unless list
      @spare_index_entry_list = nil
      list
    end

    def give_back_index_entry_list(list : IndexEntryList) : Nil
      @spare_index_entry_list = list
    end
  end
end
