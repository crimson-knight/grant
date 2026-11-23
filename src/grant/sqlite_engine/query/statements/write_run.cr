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
    @autoincrement_maximum = {} of String => Int64
    @list_of_autoincrement_tables = [] of String

    def initialize(@session : Session, @list_of_parameters : Array(Value))
    end

    def database : Database
      @session.database
    end

    def foreign_keys? : Bool
      @session.foreign_keys?
    end

    # The rules of *name*, raising "no such table" for a missing table.
    def table(name : String) : WriteTable
      @session.write_table(name) || raise SQLError.new("no such table: #{name}")
    end

    # --- INSERT -------------------------------------------------------------

    # Inserts *row* (declared column order; the rowid alias may hold the
    # rowid or NULL) into *table*. *explicit_rowid* is a rowid given by name
    # (`INSERT INTO t(rowid, ...)`) for a table without an alias. Returns the
    # outcome, the rowid and the row as stored.
    def insert_row(table : WriteTable, row : Array(Value), explicit_rowid : Value, override : ConflictAction,
                   upsert : UpsertPlan? = nil) : {InsertResult, Int64?, Array(Value)}
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
      end
      compute_generated(table, row, rowid)
      result = check_constraints(table, rowid, row, nil, override, upsert)
      return {result[0], result[1], result[2]} unless result[0].inserted?
      if replaced = result[3]
        delete_row(table, replaced[0], replaced[1], replace: true)
      end
      if foreign_keys?
        child_added(table, row)
        parent_added(table, rowid, row)
      end
      database.write_row(table.layout, rowid, row, table.list_of_index_layouts.select { |index| index_includes?(table, index, row, rowid) })
      if rowid
        note_autoincrement(table, rowid)
        if @nested == 0 && !@silent
          @session.last_insert_rowid = rowid
        end
      end
      count_change
      {InsertResult::Inserted, rowid, row}
    end

    # A row the statement changed counts in changes(); a row a foreign key
    # action changed counts at once in total_changes(), as the rows of C's
    # trigger programs do, even when the statement then fails.
    private def count_change : Nil
      return if @silent
      if @nested == 0
        @changes += 1
      else
        @session.total_changes += 1
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
        rowid = database.next_rowid(table.layout, floor)
        return rowid
      end
      database.next_rowid(table.layout)
    end

    private def autoincrement_maximum(table : WriteTable) : Int64
      key = table.name.downcase
      if value = @autoincrement_maximum[key]?
        return value
      end
      @list_of_autoincrement_tables << table.name
      @autoincrement_maximum[key] = database.sequence_of(table.name) || 0_i64
    end

    private def note_autoincrement(table : WriteTable, rowid : Int64) : Nil
      return unless table.definition.autoincrement?
      key = table.name.downcase
      current = autoincrement_maximum(table)
      @autoincrement_maximum[key] = rowid if rowid > current
    end

    # sqlite3AutoincrementBegin's tables, opened by any INSERT into them
    # (even one that inserts no row).
    def open_autoincrement(table : WriteTable) : Nil
      autoincrement_maximum(table) if table.definition.autoincrement?
    end

    # sqlite3AutoincrementEnd: each AUTOINCREMENT table's largest rowid goes
    # to sqlite_sequence when it passed the value stored there.
    def finish_autoincrement : Nil
      @list_of_autoincrement_tables.each do |name|
        value = @autoincrement_maximum[name.downcase]
        stored = database.sequence_of(name)
        next if stored && stored >= value
        database.write_sequence(name, value)
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
      # NOT NULL, in column order; REPLACE puts the DEFAULT in.
      table.list_of_columns.each do |column|
        action = column.not_null
        next unless action
        next if column.position == table.rowid_alias
        next unless row[column.position].nil?
        action = override unless override.default?
        action = ConflictAction::Abort if action.default?
        if action.replace?
          if column.default_expression
            row[column.position] = default_value(table, column)
            next unless row[column.position].nil?
          end
          action = ConflictAction::Abort
        end
        return {InsertResult::Ignored, rowid, row, nil} if action.ignore?
        raise ConstraintError.new("NOT NULL constraint failed: #{table.name}.#{column.column_name}", action)
      end
      stored = database.stored_values(definition, row)
      stored.each_with_index { |value, index| row[index] = value }
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
      ordered = table.list_of_indexes
      if upsert
        targeted = upsert.list_of_clauses.compact_map(&.index_rule)
        ordered = targeted.uniq + ordered.reject { |rule| targeted.includes?(rule) }
      end
      ordered.each do |rule|
        next unless rule.unique?
        index = rule.layout
        next unless index_includes?(table, index, row, rowid)
        entry = index.entry_for(row, rowid)
        existing = database.index_entry_matching(index, entry)
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
            delete_row(table, victim[0], victim[1], replace: true)
          end
        else
          raise ConstraintError.new(unique_message(table, rule), action)
        end
      end
      unless rowid_checked
        outcome = check_rowid(table, rowid, row, old, rowid_action, rowid_clause, upsert)
        return outcome if outcome
      end
      if rowid && !table.without_rowid? && rowid_action.replace? && !(old && old[0] == rowid)
        if victim = database.row_at(table.layout, rowid)
          replace_row = {rowid.as(Int64?), victim}
        end
      end
      {InsertResult::Inserted, rowid, row, replace_row}
    end

    # The rowid uniqueness check (nil when it passes or REPLACE resolves it).
    private def check_rowid(table : WriteTable, rowid : Int64?, row : Array(Value), old : {Int64?, Array(Value)}?,
                            action : ConflictAction, clause : UpsertClause?,
                            upsert : UpsertPlan?) : {InsertResult, Int64?, Array(Value), {Int64?, Array(Value)}?}?
      return unless rowid && !table.without_rowid?
      return if old && old[0] == rowid
      return unless database.row_exists?(table.layout, rowid)
      case action
      when .ignore?
        {InsertResult::Ignored, rowid, row, nil}
      when .update?
        target = database.row_at(table.layout, rowid) || return
        upsert_update(table, {rowid.as(Int64?), target}, row, clause || raise Error.new("upsert without a clause"))
      when .replace?
        nil
      else
        column = table.rowid_alias.try { |index| table.list_of_columns[index].column_name } || "rowid"
        raise ConstraintError.new("UNIQUE constraint failed: #{table.name}.#{column}", action)
      end
    end

    private def unique_message(table : WriteTable, rule : IndexRule) : String
      if rule.layout.unsupported_reason.try(&.starts_with?("expression"))
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
        found = database.row_at(table.layout, key)
        found ? {key.as(Int64?), found} : nil
      else
        probe = Array(Value).new(table.list_of_columns.size, nil)
        table.layout.list_of_primary_key_positions.each_with_index { |position, offset| probe[position] = key[offset] }
        found = database.row_with_key_of(table.layout, probe)
        found ? {nil.as(Int64?), found} : nil
      end
    end

    # Whether a partial index holds the row (its WHERE is true).
    def index_includes?(table : WriteTable, index : IndexLayout, row : Array(Value), rowid : Int64?) : Bool
      rule = table.list_of_indexes.find { |candidate| candidate.layout.same?(index) }
      where = rule.try(&.where)
      return true unless where
      program = table.partial_programs[index.entry.object_name] ||= begin
        pseudo = PseudoTable.new(table.name, table.table_info)
        RowProgram.new(@session, RowProgram.columns([where] of SQL::Expression), [pseudo])
      end
      pseudo = program.list_of_pseudo_tables[0]
      pseudo.row = row
      pseudo.rowid = rowid
      ValueSemantics.truth(program.evaluate(@list_of_parameters).try(&.[0]?)) == true
    end

    private def check_programs(table : WriteTable) : Array(RowProgram)
      table.check_programs ||= table.list_of_checks.map do |check|
        pseudo = PseudoTable.new(table.name, table.table_info)
        RowProgram.new(@session, RowProgram.columns([check.expression] of SQL::Expression), [pseudo])
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

    # The values of the generated columns of a new or changed row.
    def compute_generated(table : WriteTable, row : Array(Value), rowid : Int64?) : Nil
      return unless table.has_generated_columns?
      table.list_of_columns.each do |column|
        expression = column.generated_expression
        next unless expression
        raise UnsupportedSQL.new("VIRTUAL generated column #{table.name}.#{column.column_name}") unless column.generated_stored?
        program = table.generated_programs[column.position] ||= RowProgram.new(@session, RowProgram.columns([expression] of SQL::Expression),
          [PseudoTable.new(table.name, table.table_info)])
        pseudo = program.list_of_pseudo_tables[0]
        pseudo.row = row
        pseudo.rowid = rowid
        value = program.evaluate(@list_of_parameters).try(&.[0]?)
        row[column.position] = StoredValue.for_affinity(table.definition.list_of_columns[column.position].affinity, value)
      end
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
      rowid, stored = update_row(table, target[0], target[1], new_row, explicit_rowid, ConflictAction::Abort, clause.list_of_positions)
      {InsertResult::Upserted, rowid, stored, nil}
    end

    # --- UPDATE -------------------------------------------------------------

    # Replaces the row *old_row* at *old_rowid* by *new_row* (declared order,
    # before affinity). *explicit_rowid* is a new rowid set by name.
    # *list_of_changed* holds the positions the statement assigned (-1 for
    # the rowid). Returns the rowid and the row as stored.
    def update_row(table : WriteTable, old_rowid : Int64?, old_row : Array(Value), new_row : Array(Value),
                   explicit_rowid : Value, override : ConflictAction, list_of_changed : Array(Int32)) : {Int64?, Array(Value)}
      rowid = old_rowid
      unless table.without_rowid?
        if alias_index = table.rowid_alias
          if list_of_changed.includes?(alias_index)
            candidate = new_row[alias_index]
            # An UPDATE that sets the INTEGER PRIMARY KEY to NULL picks a new
            # rowid as an INSERT would.
            rowid = candidate.nil? ? new_rowid(table) : WriteRun.must_be_int(candidate)
          end
          new_row[alias_index] = rowid
        elsif list_of_changed.includes?(-1)
          rowid = explicit_rowid.nil? ? new_rowid(table) : WriteRun.must_be_int(explicit_rowid)
        end
      end
      compute_generated(table, new_row, rowid)
      result = check_constraints(table, rowid, new_row, {old_rowid, old_row}, override, nil)
      return {old_rowid, old_row} if result[0].ignored?
      if foreign_keys?
        child_removed(table, old_row, new_row, list_of_changed)
        parent_removed(table, old_rowid, old_row, new_row, list_of_changed)
      end
      layouts = table.list_of_index_layouts
      database.remove_row(table.layout, old_rowid, old_row,
        layouts.select { |index| index_includes?(table, index, old_row, old_rowid) })
      if replaced = result[3]
        delete_row(table, replaced[0], replaced[1], replace: true)
      end
      database.write_row(table.layout, rowid, new_row, layouts.select { |index| index_includes?(table, index, new_row, rowid) })
      note_autoincrement(table, rowid) if rowid
      if foreign_keys?
        child_added(table, new_row, old_row, list_of_changed)
        parent_added(table, rowid, new_row, old_row, list_of_changed)
        parent_actions(table, old_row, new_row, list_of_changed)
      end
      count_change
      {rowid, new_row}
    end

    # --- DELETE -------------------------------------------------------------

    # Deletes the row with its index entries, with foreign key processing.
    # *replace* marks a delete REPLACE makes (not counted in changes()).
    def delete_row(table : WriteTable, rowid : Int64?, row : Array(Value), replace : Bool = false) : Nil
      if foreign_keys?
        child_removed(table, row)
        parent_removed(table, rowid, row)
      end
      layouts = table.list_of_index_layouts.select { |index| index_includes?(table, index, row, rowid) }
      database.remove_row(table.layout, rowid, row, layouts)
      parent_actions(table, row, nil) if foreign_keys?
      count_change unless replace
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
        next if values.any?(&.nil?)
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
        next if values.any?(&.nil?)
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
        next if key.any?(&.nil?)
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
        next if key.any?(&.nil?)
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
        next if key.any?(&.nil?)
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
                delete_row(child_table, child_rowid, current)
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
      return database.row_at(table.layout, rowid) if rowid
      database.row_with_key_of(table.layout, row)
    end

    private def same_table?(left : String, right : String) : Bool
      left.compare(right, case_insensitive: true) == 0
    end

    # The foreign keys of every table that name *table* as parent, with the
    # parent key positions each refers to.
    private def referencing(table : WriteTable) : Array({WriteTable, ForeignKeyRule, Array(Int32)})
      list = [] of {WriteTable, ForeignKeyRule, Array(Int32)}
      @session.list_of_child_tables(table.name).each do |child_name|
        child = table(child_name)
        child.list_of_foreign_keys.each do |rule|
          next unless same_table?(rule.parent_table, table.name)
          lookup = parent_lookup(rule)
          next unless lookup
          list << {child, rule, lookup.list_of_parent_positions}
        end
      end
      list
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
        cursor = IndexCursor.new(database, info.root_page, IndexOrder.new([] of Collation, [] of Bool))
        moved = cursor.first
        while moved
          yield nil, info.row_from(nil, cursor.record)
          moved = cursor.advance
        end
      else
        cursor = TableCursor.new(database, info.root_page)
        moved = cursor.first
        while moved
          rowid = cursor.rowid
          yield rowid, info.row_from(rowid, cursor.record)
          moved = cursor.advance
        end
      end
    end

    @parent_lookups = {} of ForeignKeyRule => ParentLookup?

    # How to find a foreign key's parent row; raises C's errors for a
    # missing parent table and for parent columns without a UNIQUE index.
    private def parent_lookup(rule : ForeignKeyRule) : ParentLookup?
      return @parent_lookups[rule] if @parent_lookups.has_key?(rule)
      parent_info = @session.table(rule.parent_table)
      raise SQLError.new("no such table: main.#{rule.parent_table}") unless parent_info
      parent = table(rule.parent_table)
      @parent_lookups[rule] = ParentLookup.locate(self, rule, parent)
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
      database = @run.database
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
end
