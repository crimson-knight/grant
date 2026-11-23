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
  # from a SELECT or several VALUES rows, a RETURNING clause, a REPLACE
  # that deletes rows, and an UPDATE or DELETE that is not one-pass.
  module StatementJournal
    AGGREGATE_NAMES = %w[COUNT SUM TOTAL AVG MIN MAX GROUP_CONCAT STRING_AGG]
    # Keywords that read as functions when a parenthesis follows them.
    FUNCTION_KEYWORDS = %w[REPLACE LIKE GLOB IF]

    # True when *text* (SQL expressions) calls a function: a name before
    # "(" that is no keyword, or a LIKE, GLOB, REGEXP or MATCH operator.
    def self.calls_function?(text : String) : Bool
      stripped = text.gsub(/'(?:[^']|'')*'/, "''")
      return true if stripped.matches?(/\b(LIKE|GLOB|REGEXP|MATCH)\b/i)
      stripped.scan(/([A-Za-z_][A-Za-z0-9_$]*)\s*\(/).any? do |match|
        name = match[1].upcase
        next false if AGGREGATE_NAMES.includes?(name)
        !SQL::Keywords::TABLE.has_key?(name) || FUNCTION_KEYWORDS.includes?(name)
      end
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
      multi = several_rows || !statement.returning.nil?
      texts = [] of String
      statement.source.try { |source| texts << source.to_sql }
      statement.returning.try { |columns| texts.concat(column_texts(columns)) }
      statement.upserts.each do |upsert|
        upsert.assignments.try { |list| list.each { |assignment| texts << assignment.value.to_sql } }
        upsert.where.try { |where| texts << where.to_sql }
      end
      may_abort = true if statement.upserts.any? { |upsert| !upsert.assignments.nil? }
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
        action = ConflictAction::Abort if action.replace? && column.default_expression.nil?
        may_abort = true if action.abort?
      end
      unless table.list_of_checks.empty?
        action = resolved(override, nil)
        may_abort = true if action.abort? || action.replace?
      end
      rowid_given = table.rowid_alias.try { |position| given.includes?(position) } || given.includes?(-1)
      if rowid_given && !table.without_rowid?
        action = untargeted_nothing ? ConflictAction::Ignore : resolved(override, table.rowid_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace? && !table.list_of_indexes.empty?
      end
      if table.without_rowid?
        action = untargeted_nothing ? ConflictAction::Ignore : resolved(override, table.primary_key_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace?
      end
      table.list_of_indexes.each do |rule|
        next unless rule.unique?
        action = untargeted_nothing ? ConflictAction::Ignore : resolved(override, rule.conflict)
        may_abort = true if action.abort?
        multi = true if action.replace?
      end
      if session.foreign_keys? && table.list_of_foreign_keys.any? { |rule| !rule.deferred? }
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
        action = ConflictAction::Abort if action.replace? && column.default_expression.nil?
        may_abort = true if action.abort?
      end
      unless checks.empty?
        action = resolved(override, nil)
        may_abort = true if action.abort? || action.replace?
      end
      if rowid_changed && !table.without_rowid?
        action = resolved(override, table.rowid_conflict)
        may_abort = true if action.abort?
        multi = true if action.replace? && !table.list_of_indexes.empty?
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

    private def self.column_texts(columns : Array(SQL::ResultColumn)) : Array(String)
      columns.compact_map { |column| column.is_a?(SQL::ExpressionColumn) ? column.expression.to_sql : nil }
    end

    private def self.mentions_any?(text : String, names : Array(String)) : Bool
      lowered = text.downcase
      names.any? { |name| lowered.matches?(/(?<![\w])#{Regex.escape(name)}(?![\w])/) }
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
