module Grant::SQLiteEngine::Query
  # Whether C gives a write statement a statement journal
  # (`usesStmtJournal = isMultiWrite && mayAbort`, sqlite3VdbeMakeReady).
  # Without one, a runtime error that is no constraint ABORT (such as
  # "datatype mismatch" for a rowid) leaves the rows the statement already
  # wrote inside an open transaction; with one they are undone.
  #
  # mayAbort (sqlite3MayAbort) is set by every non-aggregate function
  # call, every constraint check that resolves to ABORT, an immediate
  # foreign key, and an upsert's DO UPDATE. isMultiWrite
  # (sqlite3MultiWrite, sqlite3BeginWriteOperation) is set by an INSERT
  # from a SELECT or several VALUES rows, a DO UPDATE upsert, a RETURNING
  # clause, a REPLACE that deletes rows, and an UPDATE or DELETE that is not one-pass.
  module StatementJournal
    AGGREGATE_NAMES = %w[COUNT SUM TOTAL AVG MIN MAX GROUP_CONCAT STRING_AGG]
    # Keywords that read as functions when a parenthesis follows them.
    FUNCTION_KEYWORDS = %w[REPLACE LIKE GLOB IF]
    # Operators that call a function (likeFunc, globFunc, regexp, match).
    PATTERN_OPERATORS = %w[LIKE GLOB REGEXP MATCH]

    # True when *text* (SQL expressions) calls a function: a name before
    # "(" that is no keyword, or a LIKE, GLOB, REGEXP or MATCH operator.
    def self.calls_function?(text : String) : Bool
      stripped = TextScan.blank_quoted_strings(text)
      return true if TextScan.contains_any_word?(stripped, PATTERN_OPERATORS)
      TextScan.each_function_name(stripped) do |written_name|
        name = written_name.upcase
        next if AGGREGATE_NAMES.includes?(name)
        return true if !SQL::Keywords::TABLE.has_key?(name) || FUNCTION_KEYWORDS.includes?(name)
      end
      false
    end

    # The action a constraint resolves to: the statement's OR clause, else
    # the constraint's own, else ABORT.
    def self.resolved(override : ConflictAction, own : ConflictAction?) : ConflictAction
      action = override.default? ? (own || ConflictAction::Default) : override
      action.default? ? ConflictAction::Abort : action
    end

    # {isMultiWrite, usesStmtJournal} of an INSERT.
    def self.for_insert(session : Session, table : WriteTable, statement : SQL::Insert, override : ConflictAction,
                        list_of_positions : Array(Int32), several_rows : Bool) : {Bool, Bool}
      may_abort = false
      replaces = false
      multi = several_rows || !statement.returning.nil?
      texts = [] of String
      statement.source.try { |source| texts << source.to_sql }
      statement.returning.try { |columns| texts.concat(column_texts(columns)) }
      statement.upserts.each do |upsert|
        upsert.assignments.try { |list| list.each { |assignment| texts << assignment.value.to_sql } }
        upsert.where.try { |where| texts << where.to_sql }
      end
      # A DO UPDATE is compiled (sqlite3UpsertDoUpdate) where C checks its
      # target: a rowid target only when the INSERT names the rowid. One
      # that changes a foreign key column (as child, or a key other tables
      # reference) makes the INSERT a multi-write, so its foreign keys are
      # counted and checked when the statement ends.
      rowid_named = table.rowid_alias.try { |position| list_of_positions.includes?(position) } || list_of_positions.includes?(-1)
      statement.upserts.each do |upsert|
        assignments = upsert.assignments
        next unless assignments
        next if !rowid_named && targets_rowid?(table, upsert)
        changed = assignments.flat_map(&.columns).map { |name| table.table_info.column_index(name.value) || -1 }
        may_abort = true if upsert_update_may_abort?(session, table, changed)
        multi = true if session.foreign_keys? && foreign_key_columns_change?(session, table, changed)
      end
      untargeted_nothing = statement.upserts.any? { |upsert| upsert.target.nil? && upsert.assignments.nil? }
      given = list_of_positions.to_set
      table.list_of_columns.each do |column|
        next if given.includes?(column.position) || column.position == table.rowid_alias
        column.default_expression.try { |expression| texts << expression.to_sql }
        column.generated_expression.try { |expression| texts << expression.to_sql }
      end
      table.list_of_checks.each { |check| texts << check.expression.to_sql }
      may_abort = true if texts.any? { |text| calls_function?(text) }
      table.list_of_columns.each do |column|
        own = column.not_null
        next unless own
        next if column.position == table.rowid_alias
        action = resolved(override, own)
        # REPLACE takes a second pass that checks the column as ABORT.
        action = ConflictAction::Abort if action.replace?
        may_abort = true if action.abort?
      end
      unless table.list_of_checks.empty?
        action = resolved(override, nil)
        may_abort = true if action.abort? || action.replace?
      end
      rowid_given = table.rowid_alias.try { |position| given.includes?(position) } || given.includes?(-1)
      if rowid_given && !table.without_rowid?
        action = untargeted_nothing || targets_rowid_in?(table, statement) ? ConflictAction::Ignore : resolved(override, table.rowid_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace? && (!table.list_of_indexes.empty? || foreign_keys_required?(session, table))
        replaces = true if action.replace?
      end
      if table.without_rowid?
        action = untargeted_nothing || targets_columns?(statement, table.definition.list_of_primary_key_columns) ? ConflictAction::Ignore : resolved(override, table.primary_key_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace?
        replaces = true if action.replace?
      end
      table.list_of_indexes.each do |rule|
        next unless rule.unique?
        names = rule.layout.list_of_key_positions.map { |position| position >= 0 ? table.list_of_columns[position].column_name : "" }
        action = untargeted_nothing || targets_columns?(statement, names) ? ConflictAction::Ignore : resolved(override, rule.conflict)
        may_abort = true if action.abort?
        multi = true if action.replace?
        replaces = true if action.replace?
      end
      if session.foreign_keys? && table.list_of_foreign_keys.any? { |rule| !rule.deferred? }
        may_abort = true
      end
      # A REPLACE deletes the row it displaces with sqlite3GenerateRowDelete,
      # whose foreign key checks and actions count as an ABORT path whenever
      # the table takes part in a foreign key (as child or parent).
      if replaces && foreign_keys_required?(session, table)
        may_abort = true
      end
      {multi, multi && may_abort}
    end

    def self.for_update(session : Session, table : WriteTable, statement : SQL::Update, override : ConflictAction,
                        list_of_changed : Array(Int32)) : Bool
      may_abort = false
      multi = !single_row?(table, statement.where) || !statement.from.nil? || !statement.returning.nil?
      texts = statement.assignments.map(&.value.to_sql)
      statement.where.try { |where| texts << where.to_sql }
      statement.from.try { |from| texts << from.to_sql }
      statement.returning.try { |columns| texts.concat(column_texts(columns)) }
      changed_names = list_of_changed.compact_map { |position| position >= 0 ? table.list_of_columns[position].column_name.downcase : nil }
      rowid_changed = list_of_changed.includes?(-1) || table.rowid_alias.try { |position| list_of_changed.includes?(position) } || false
      checks = table.list_of_checks.select { |check| rowid_changed || mentions_any?(check.expression.to_sql, changed_names) }
      checks.each { |check| texts << check.expression.to_sql }
      may_abort = true if texts.any? { |text| calls_function?(text) }
      table.list_of_columns.each do |column|
        own = column.not_null
        next unless own && list_of_changed.includes?(column.position)
        next if column.position == table.rowid_alias
        action = resolved(override, own)
        # REPLACE takes a second pass that checks the column as ABORT.
        action = ConflictAction::Abort if action.replace?
        may_abort = true if action.abort?
      end
      unless checks.empty?
        action = resolved(override, nil)
        may_abort = true if action.abort? || action.replace?
      end
      if rowid_changed && !table.without_rowid?
        action = resolved(override, table.rowid_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace? && (!table.list_of_indexes.empty? || foreign_keys_required?(session, table))
      end
      table.list_of_indexes.each do |rule|
        next unless rule.unique?
        positions = rule.layout.list_of_key_positions
        next unless rowid_changed || positions.any? { |position| list_of_changed.includes?(position) }
        action = resolved(override, rule.conflict)
        may_abort = true if action.abort?
        multi = true if action.replace?
      end
      if session.foreign_keys?
        child = table.list_of_foreign_keys.any? do |rule|
          !rule.deferred? && rule.list_of_child_positions.any? { |position| list_of_changed.includes?(position) }
        end
        may_abort = true if child || parent_may_abort?(session, table, rowid_changed ? nil : list_of_changed, &.on_update)
        replaces = override.replace? || table.rowid_conflict.replace? || table.list_of_indexes.any?(&.conflict.replace?)
        may_abort = true if replaces && foreign_keys_required?(session, table)
      end
      multi && may_abort
    end

    def self.for_delete(session : Session, table : WriteTable, statement : SQL::Delete) : Bool
      multi = !single_row?(table, statement.where) || !statement.returning.nil?
      texts = [] of String
      statement.where.try { |where| texts << where.to_sql }
      statement.returning.try { |columns| texts.concat(column_texts(columns)) }
      may_abort = texts.any? { |text| calls_function?(text) }
      may_abort = true if session.foreign_keys? && parent_may_abort?(session, table, nil, &.on_delete)
      multi && may_abort
    end

    # Whether C visits an UPDATE's rows in rowid order: unless it runs
    # one-pass over its scan (ONEPASS_MULTI), it collects the rowids in an
    # ephemeral table first. One-pass needs no RETURNING (a trigger), no
    # FROM, no foreign key work, no rowid change, no REPLACE, no subquery
    # in WHERE, and a scan index the statement does not change.
    def self.update_in_rowid_order?(session : Session, table : WriteTable, statement : SQL::Update,
                                    override : ConflictAction, list_of_changed : Array(Int32), scan_index_root : UInt32?) : Bool
      return true unless statement.returning.nil? && statement.from.nil?
      return true if list_of_changed.includes?(-1) || table.rowid_alias.try { |position| list_of_changed.includes?(position) }
      return true if override.replace? || table.rowid_conflict.replace? || table.list_of_indexes.any?(&.conflict.replace?)
      if session.foreign_keys?
        child = table.list_of_foreign_keys.any? { |rule| rule.list_of_child_positions.any? { |position| list_of_changed.includes?(position) } }
        return true if child || !session.list_of_child_tables(table.name).empty?
      end
      where = statement.where
      return true if where && TextScan.contains_word?(where.to_sql, "SELECT")
      return false unless scan_index_root
      table.list_of_indexes.any? do |rule|
        rule.layout.entry.root_page == scan_index_root &&
          rule.layout.list_of_key_positions.any? { |position| list_of_changed.includes?(position) }
      end
    end

    # Whether C visits a DELETE's rows in rowid order (a RowSet) rather
    # than one-pass over its scan: triggers (RETURNING), foreign key work
    # and subqueries in WHERE take the two-pass path.
    def self.delete_in_rowid_order?(session : Session, table : WriteTable, statement : SQL::Delete) : Bool
      return true unless statement.returning.nil?
      return true if foreign_keys_required?(session, table)
      where = statement.where
      !where.nil? && TextScan.contains_word?(where.to_sql, "SELECT")
    end

    # An immediate foreign key naming *table* as parent whose action is
    # neither CASCADE nor SET NULL (*list_of_changed* nil: any parent key).
    private def self.parent_may_abort?(session : Session, table : WriteTable, list_of_changed : Array(Int32)?,
                                       & : ForeignKeyRule -> String) : Bool
      session.list_of_child_tables(table.name).any? do |child_name|
        child = session.write_table(child_name)
        next false unless child
        child.list_of_foreign_keys.any? do |rule|
          next false unless rule.parent_table.compare(table.name, case_insensitive: true) == 0
          next false if rule.deferred?
          action = (yield rule).upcase
          next false if action == "CASCADE" || action == "SET NULL"
          next true unless list_of_changed
          names = rule.list_of_parent_columns
          next true unless names
          names.any? { |name| table.table_info.column_index(name).try { |position| list_of_changed.includes?(position) } }
        end
      end
    end

    # sqlite3FkRequired(pTab, 0, 0): deleting a row of *table* runs foreign
    # key actions or checks, so a REPLACE of its rowid deletes the old row
    # as a separate write.
    private def self.foreign_keys_required?(session : Session, table : WriteTable) : Bool
      session.foreign_keys? && (!table.list_of_foreign_keys.empty? || !session.list_of_child_tables(table.name).empty?)
    end

    # sqlite3FkRequired(pTab, aChange, chngRowid) for an UPDATE of
    # *list_of_changed* (-1: the rowid).
    private def self.foreign_key_columns_change?(session : Session, table : WriteTable, list_of_changed : Array(Int32)) : Bool
      rowid_changed = list_of_changed.includes?(-1) || table.rowid_alias.try { |position| list_of_changed.includes?(position) } || false
      child = table.list_of_foreign_keys.any? { |rule| rule.list_of_child_positions.any? { |position| list_of_changed.includes?(position) } }
      return true if child
      session.list_of_child_tables(table.name).any? do |child_name|
        child_table = session.write_table(child_name)
        next false unless child_table
        child_table.list_of_foreign_keys.any? do |rule|
          next false unless rule.parent_table.compare(table.name, case_insensitive: true) == 0
          names = rule.list_of_parent_columns
          next rowid_changed || list_of_changed.any? { |position| position >= 0 && table.table_info.definition.list_of_primary_key_columns.any? { |key| key.compare(table.list_of_columns[position].column_name, case_insensitive: true) == 0 } } unless names
          names.any? { |name| table.table_info.column_index(name).try { |position| list_of_changed.includes?(position) } || (rowid_changed && RowidName.rowid?(table.table_info, name)) }
        end
      end
    end

    # The constraint checks of an upsert's DO UPDATE that resolve to ABORT:
    # NOT NULL, CHECK and UNIQUE on the columns it changes, the rowid, and
    # immediate foreign keys.
    private def self.upsert_update_may_abort?(session : Session, table : WriteTable, list_of_changed : Array(Int32)) : Bool
      rowid_changed = list_of_changed.includes?(-1) || table.rowid_alias.try { |position| list_of_changed.includes?(position) } || false
      changed_names = list_of_changed.compact_map { |position| position >= 0 ? table.list_of_columns[position].column_name.downcase : nil }
      not_null = table.list_of_columns.any? do |column|
        own = column.not_null
        own && list_of_changed.includes?(column.position) && column.position != table.rowid_alias && !resolved(ConflictAction::Default, own).ignore?
      end
      return true if not_null || rowid_changed
      return true if table.list_of_checks.any? { |check| mentions_any?(check.expression.to_sql, changed_names) }
      unique = table.list_of_indexes.any? do |rule|
        rule.unique? && rule.layout.list_of_key_positions.any? { |position| list_of_changed.includes?(position) } &&
          resolved(ConflictAction::Default, rule.conflict).abort?
      end
      return true if unique
      session.foreign_keys? && foreign_key_columns_change?(session, table, list_of_changed)
    end

    # Some upsert of *statement* resolves conflicts on the rowid (its
    # action is the upsert's, never ABORT).
    private def self.targets_rowid_in?(table : WriteTable, statement : SQL::Insert) : Bool
      statement.upserts.any? { |upsert| targets_rowid?(table, upsert) }
    end

    # Some upsert of *statement* targets exactly the columns *names*.
    private def self.targets_columns?(statement : SQL::Insert, names : Array(String)) : Bool
      wanted = names.map(&.downcase).sort!
      statement.upserts.any? do |upsert|
        terms = upsert.target
        next false unless terms && upsert.target_where.nil?
        found = terms.compact_map do |term|
          expression = term.expression
          expression = expression.operand if expression.is_a?(SQL::Collate)
          expression.is_a?(SQL::ColumnReference) ? expression.column.value.downcase : nil
        end
        found.size == terms.size && found.sort! == wanted
      end
    end

    # An upsert whose conflict target is the rowid alone.
    private def self.targets_rowid?(table : WriteTable, upsert : SQL::Upsert) : Bool
      return false if table.without_rowid?
      terms = upsert.target
      return false unless terms && terms.size == 1
      expression = terms[0].expression
      return false unless expression.is_a?(SQL::ColumnReference)
      name = expression.column.value
      RowidName.rowid?(table.table_info, name) ||
        table.rowid_alias.try { |position| table.list_of_columns[position].column_name.compare(name, case_insensitive: true) == 0 } || false
    end

    private def self.column_texts(columns : Array(SQL::ResultColumn)) : Array(String)
      columns.compact_map { |column| column.is_a?(SQL::ExpressionColumn) ? column.expression.to_sql : nil }
    end

    private def self.mentions_any?(text : String, names : Array(String)) : Bool
      lowered = text.downcase
      names.any? { |name| TextScan.contains_word?(lowered, name, case_insensitive: false) }
    end

    # One-pass in C: a WHERE that names one row by its rowid.
    private def self.single_row?(table : WriteTable, where : SQL::Expression?) : Bool
      return false unless where.is_a?(SQL::BinaryOperation) && (where.operator.equal? || where.operator.double_equal?)
      [{where.left, where.right}, {where.right, where.left}].any? do |column, value|
        next false unless column.is_a?(SQL::ColumnReference)
        name = column.column.value
        rowid = RowidName.rowid?(table.table_info, name) ||
                table.rowid_alias.try { |position| table.list_of_columns[position].column_name.compare(name, case_insensitive: true) == 0 } || false
        rowid && (value.is_a?(SQL::Literal) || value.is_a?(SQL::Parameter))
      end
    end
  end
end
