module Grant::SQLiteEngine::Query
  # A conflict resolution as C applies it (OE_*): Default is the absence of
  # an ON CONFLICT clause.
  enum ConflictAction
    Default
    Rollback
    Abort
    Fail
    Ignore
    Replace
    Update

    def self.from(resolution : SQL::ConflictResolution?) : ConflictAction
      case resolution
      when Nil        then Default
      when .rollback? then Rollback
      when .abort?    then Abort
      when .fail?     then Fail
      when .ignore?   then Ignore
      else                 Replace
      end
    end
  end

  # What a write needs to know about one column beyond its definition.
  class ColumnRule
    getter position : Int32
    getter column_name : String
    # The NOT NULL constraint's conflict action, or nil without one.
    property not_null : ConflictAction? = nil
    property default_expression : SQL::Expression? = nil
    property generated_expression : SQL::Expression? = nil
    property? generated_stored = false

    def initialize(@position : Int32, @column_name : String)
    end

    def generated? : Bool
      !@generated_expression.nil?
    end
  end

  # One CHECK constraint: its name for the error message (the CONSTRAINT
  # name, or the text between its parentheses) and its expression.
  record CheckRule, constraint_name : String, expression : SQL::Expression

  # One index as constraint checks see it: C's conflict action, for a
  # partial index its WHERE, and the expressions of its expression terms
  # in key order.
  class IndexRule
    getter layout : IndexLayout
    getter conflict : ConflictAction
    getter where : SQL::Expression?
    # "t.a, t.b": the columns C's UNIQUE message lists.
    getter columns_text : String
    getter list_of_key_expressions : Array(SQL::Expression)

    def initialize(@layout : IndexLayout, @conflict : ConflictAction, @where : SQL::Expression?, @columns_text : String,
                   @list_of_key_expressions : Array(SQL::Expression) = [] of SQL::Expression)
    end

    def unique? : Bool
      @layout.unique?
    end
  end

  # A FOREIGN KEY of a child table.
  class ForeignKeyRule
    getter child_table : String
    getter list_of_child_positions : Array(Int32)
    getter parent_table : String
    # The parent columns the clause names, or nil for the parent's primary key.
    getter list_of_parent_columns : Array(String)?
    getter on_delete : String
    getter on_update : String
    getter? deferred : Bool

    def initialize(@child_table : String, @list_of_child_positions : Array(Int32), @parent_table : String,
                   @list_of_parent_columns : Array(String)?, @on_delete : String, @on_update : String, @deferred : Bool)
    end
  end

  # A table's rules for writing rows, read from its CREATE TABLE: column
  # defaults, NOT NULL and generated columns, CHECK constraints, the rowid's
  # conflict action, the indexes in the order C checks them, and its
  # foreign keys.
  class WriteTable
    getter table_info : TableInfo
    getter layout : TableLayout
    getter list_of_columns : Array(ColumnRule)
    getter list_of_checks = [] of CheckRule
    getter list_of_indexes : Array(IndexRule)
    getter list_of_foreign_keys = [] of ForeignKeyRule
    getter rowid_conflict = ConflictAction::Default
    # The PRIMARY KEY's conflict action of a WITHOUT ROWID table, whose key
    # is the table b-tree's own (it has no separate index).
    getter primary_key_conflict = ConflictAction::Default
    # Where a WITHOUT ROWID table's PRIMARY KEY sits in `list_of_indexes`'
    # check order: C checks it as the index it was created as.
    getter primary_key_position = 0

    # The order unique keys are checked in without an upsert: every index,
    # with nil standing for a WITHOUT ROWID table's PRIMARY KEY.
    getter list_of_rules_in_check_order : Array(IndexRule?) do
      ordered = list_of_indexes.map(&.as(IndexRule?))
      ordered.insert(primary_key_position, nil) if without_rowid?
      ordered
    end
    # Compiled expressions, kept while the schema stays the same.
    property check_programs : Array(RowProgram)? = nil
    getter partial_programs = {} of String => RowProgram
    getter key_expression_programs = {} of String => RowProgram
    getter default_programs = {} of Int32 => RowProgram
    getter generated_programs = {} of Int32 => RowProgram

    def initialize(@table_info : TableInfo, @layout : TableLayout)
      definition = @table_info.definition
      @list_of_columns = definition.list_of_columns.map_with_index { |column, index| ColumnRule.new(index, column.column_name) }
      constraint_conflicts = [] of {Array(String), ConflictAction}
      sql = @table_info.entry.sql
      statement = sql ? SQL::Parser.parse_schema(sql) : nil
      if statement.is_a?(SQL::CreateTable)
        read_constraints(statement, constraint_conflicts)
        names = WriteTable.check_names(sql || "")
        @list_of_checks.map_with_index! do |check, index|
          CheckRule.new(names[index]? || check.constraint_name, check.expression)
        end
      end
      read_primary_key(constraint_conflicts) if without_rowid?
      rules = @table_info.list_of_indexes.map do |index|
        where, expressions = index_syntax(index)
        IndexRule.new(index, index_conflict(index, constraint_conflicts), where, columns_text(index), expressions)
      end
      # sqlite3CreateIndex links each new index at the head of the table's
      # list, then moves REPLACE indexes to the end.
      rules.reverse!
      @list_of_indexes = rules.reject(&.conflict.replace?) + rules.select(&.conflict.replace?)
      @primary_key_position = primary_key_slot(rules) if without_rowid?
    end

    # The PRIMARY KEY of a WITHOUT ROWID table is the automatic index whose
    # number sqlite_master lacks (its b-tree is the table's). Indexes created
    # after it (higher numbers, then CREATE INDEX) are checked before it;
    # REPLACE indexes, and a REPLACE key, go last.
    private def primary_key_slot(rules : Array(IndexRule)) : Int32
      prefix = "sqlite_autoindex_#{name}_"
      numbers = rules.compact_map do |rule|
        object_name = rule.layout.entry.object_name
        object_name.starts_with?(prefix) ? object_name[prefix.size..].to_i? : nil
      end.to_set
      key_number = (1..).find { |number| !numbers.includes?(number) } || 1
      newer = ->(rule : IndexRule) do
        object_name = rule.layout.entry.object_name
        number = object_name.starts_with?(prefix) ? object_name[prefix.size..].to_i? : nil
        number.nil? || number > key_number
      end
      action = @primary_key_conflict
      return @list_of_indexes.size if action.replace?
      @list_of_indexes.count { |rule| !rule.conflict.replace? && newer.call(rule) }
    end

    def name : String
      @table_info.name
    end

    # The database holding the table (main or temp).
    def database : Database
      @table_info.database
    end

    def definition : TableDefinition
      @table_info.definition
    end

    def rowid_alias : Int32?
      @table_info.rowid_alias
    end

    def without_rowid? : Bool
      @table_info.without_rowid?
    end

    def has_generated_columns? : Bool
      @list_of_columns.any?(&.generated?)
    end

    def list_of_index_layouts : Array(IndexLayout)
      @table_info.list_of_indexes
    end

    # convertToWithoutRowidTable: every PRIMARY KEY column without a NOT
    # NULL of its own is NOT NULL (ABORT).
    private def read_primary_key(constraint_conflicts : Array({Array(String), ConflictAction})) : Nil
      key_names = definition.list_of_primary_key_columns.map(&.downcase)
      @list_of_columns.each do |rule|
        next unless key_names.includes?(rule.column_name.downcase)
        rule.not_null ||= ConflictAction::Abort
      end
      if found = constraint_conflicts.find { |names, _| names.sort == key_names.sort }
        @primary_key_conflict = found[1]
      end
    end

    private def read_constraints(statement : SQL::CreateTable, constraint_conflicts : Array({Array(String), ConflictAction})) : Nil
      statement.columns.each_with_index do |column_syntax, position|
        rule = @list_of_columns[position]? || next
        constraint_name = nil
        column_syntax.constraints.each do |constraint|
          case constraint
          when SQL::ConstraintName
            constraint_name = constraint.name.value
          when SQL::NotNullConstraint
            rule.not_null = ConflictAction.from(constraint.conflict)
          when SQL::DefaultConstraint
            rule.default_expression = constraint.value
          when SQL::GeneratedConstraint
            rule.generated_expression = constraint.expression
            rule.generated_stored = constraint.storage.try(&.same?("STORED")) || false
          when SQL::CheckColumnConstraint
            @list_of_checks << CheckRule.new(constraint_name || "", constraint.expression)
          when SQL::PrimaryKeyColumnConstraint
            conflict = ConflictAction.from(constraint.conflict)
            if position == @table_info.rowid_alias
              @rowid_conflict = conflict
            else
              constraint_conflicts << {[rule.column_name.downcase], conflict}
            end
          when SQL::UniqueColumnConstraint
            constraint_conflicts << {[rule.column_name.downcase], ConflictAction.from(constraint.conflict)}
          when SQL::ReferencesConstraint
            add_foreign_key([position], constraint.clause)
          when SQL::DeferrableConstraint
            if last = @list_of_foreign_keys.last?
              @list_of_foreign_keys[-1] = ForeignKeyRule.new(last.child_table, last.list_of_child_positions, last.parent_table,
                last.list_of_parent_columns, last.on_delete, last.on_update, WriteTable.deferred?(constraint.deferrability))
            end
          end
        end
      end
      statement.constraints.each do |constraint|
        case constraint
        when SQL::PrimaryKeyTableConstraint
          names = key_names(constraint.columns)
          conflict = ConflictAction.from(constraint.conflict)
          if names.size == 1 && (alias_index = @table_info.rowid_alias) && names[0] == @list_of_columns[alias_index].column_name.downcase
            @rowid_conflict = conflict
          else
            constraint_conflicts << {names, conflict}
          end
        when SQL::UniqueTableConstraint
          constraint_conflicts << {key_names(constraint.columns), ConflictAction.from(constraint.conflict)}
        when SQL::CheckTableConstraint
          @list_of_checks << CheckRule.new("", constraint.expression)
        when SQL::ForeignKeyTableConstraint
          positions = constraint.columns.map do |column|
            @table_info.column_index(column.value) || raise SQLError.new("unknown column \"#{column.value}\" in foreign key definition")
          end
          add_foreign_key(positions, constraint.clause)
        end
      end
    end

    private def key_names(terms : Array(SQL::OrderingTerm)) : Array(String)
      terms.map do |term|
        expression = term.expression
        while expression.is_a?(SQL::Collate)
          expression = expression.operand
        end
        expression.is_a?(SQL::ColumnReference) ? expression.column.value.downcase : expression.to_sql.downcase
      end
    end

    private def add_foreign_key(positions : Array(Int32), clause : SQL::ForeignKeyClause) : Nil
      on_delete = clause.actions.find(&.event.==("DELETE")).try(&.action) || "NO ACTION"
      on_update = clause.actions.find(&.event.==("UPDATE")).try(&.action) || "NO ACTION"
      @list_of_foreign_keys << ForeignKeyRule.new(name, positions, clause.table.value, clause.columns.try(&.map(&.value)),
        on_delete, on_update, WriteTable.deferred?(clause.deferrability))
    end

    def self.deferred?(deferrability : SQL::Deferrability?) : Bool
      return false unless deferrability
      !deferrability.negated && deferrability.initially == "DEFERRED"
    end

    private def index_conflict(index : IndexLayout, constraint_conflicts : Array({Array(String), ConflictAction})) : ConflictAction
      return ConflictAction::Default unless index.unique?
      return ConflictAction::Default unless index.entry.sql.nil?
      names = index.list_of_key_positions.map { |position| @list_of_columns[position].column_name.downcase }
      found = constraint_conflicts.find { |columns, _| columns == names }
      found ? found[1] : ConflictAction::Default
    end

    # A CREATE INDEX's WHERE and the expressions of its expression terms
    # (the positions `IndexLayout::EXPRESSION` marks), in key order.
    private def index_syntax(index : IndexLayout) : {SQL::Expression?, Array(SQL::Expression)}
      expressions = [] of SQL::Expression
      sql = index.entry.sql
      return {nil, expressions} unless sql && index.needs_evaluation?
      statement = SQL::Parser.parse_schema(sql)
      return {nil, expressions} unless statement.is_a?(SQL::CreateIndex)
      statement.columns.each_with_index do |term, position|
        next unless index.list_of_key_positions[position]? == IndexLayout::EXPRESSION
        expression = term.expression
        expression = expression.operand if expression.is_a?(SQL::Collate)
        expressions << expression
      end
      {statement.where, expressions}
    end

    private def columns_text(index : IndexLayout) : String
      index.list_of_key_positions.map do |position|
        position >= 0 ? "#{name}.#{@list_of_columns[position].column_name}" : "#{name}.<expr>"
      end.join(", ")
    end

    # The name each CHECK constraint of *sql* carries in C's message, in
    # declaration order: its CONSTRAINT name, or its text between the
    # parentheses (sqlite3AddCheckConstraint). A CONSTRAINT name holds until
    # the next column or table constraint.
    #
    # The text goes through sqlite3Dequote: text that opens with a quote
    # character becomes what that quoted span holds, so CHECK ("rating" >= 0)
    # is named rating; other text is kept whole.
    def self.check_names(sql : String) : Array(String)
      tokenizer = SQL::Tokenizer.new(sql)
      tokens = [] of SQL::Token
      loop do
        token = tokenizer.next_token
        break if token.kind.end_of_input? || token.kind.illegal?
        tokens << token
      end
      names = [] of String
      depth = 0
      constraint_name = nil
      index = 0
      while index < tokens.size
        token = tokens[index]
        case token.kind
        when .left_paren?  then depth += 1
        when .right_paren? then depth -= 1
        when .comma?
          constraint_name = nil if depth == 1
        when .constraint?
          if depth == 1 && (name_token = tokens[index + 1]?)
            constraint_name = SQL::Parser.dequote(tokenizer.text(name_token))
            index += 1
          end
        when .check?
          if depth == 1 && (open = tokens[index + 1]?) && open.kind.left_paren?
            level = 0
            close = index + 1
            while close < tokens.size
              level += 1 if tokens[close].kind.left_paren?
              level -= 1 if tokens[close].kind.right_paren?
              break if level == 0
              close += 1
            end
            close_token = tokens[close]? || break
            start = open.start + 1
            text = sql.byte_slice(start, close_token.start - start).strip
            names << (constraint_name || WriteTable.dequoted(text))
            index = close
          end
        end
        index += 1
      end
      names
    end

    # util.c sqlite3Dequote: the content of the quoted span *text* opens
    # with (a doubled closing quote stands for one), or *text* unchanged
    # when it does not open with a quote character.
    def self.dequoted(text : String) : String
      opening = text[0]?
      return text unless opening && opening.in?('"', '\'', '`', '[')
      closing = opening == '[' ? ']' : opening
      reader = Char::Reader.new(text)
      reader.next_char
      String.build do |io|
        while reader.has_next?
          char = reader.current_char
          if char == closing
            break unless reader.peek_next_char == closing
            reader.next_char
          end
          io << char
          reader.next_char
        end
      end
    end
  end
end
