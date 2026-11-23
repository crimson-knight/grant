module Grant::SQLiteEngine::SQL
  # CREATE TABLE and column definitions (lang_createtable.html), with the
  # checks build.c makes while the parser builds the table: duplicate and
  # too many columns, one primary key, AUTOINCREMENT only on an INTEGER
  # PRIMARY KEY, constant defaults, generated-column rules, and foreign key
  # column counts.
  module TableParsing
    # What the parser knows about the table it is building.
    # :nodoc:
    class TableUnderConstruction
      getter name : String
      getter column_names = [] of String
      getter? has_primary_key = false
      # Per column: part of the primary key, generated, has a DEFAULT.
      getter primary_key_columns = Set(Int32).new
      getter generated_columns = Set(Int32).new
      getter defaulted_columns = Set(Int32).new
      getter integer_columns = Set(Int32).new
      # The PRIMARY KEY and UNIQUE indexes so far: columns, collations, conflict.
      getter key_indexes = [] of {Array(Int32), Array(String), ConflictResolution?}

      def initialize(@name : String)
      end

      def mark_primary_key : Nil
        @has_primary_key = true
      end

      def column_index(name : String) : Int32?
        @column_names.index { |existing| existing.compare(name, case_insensitive: true) == 0 }
      end
    end

    private def parse_create_table(temporary : Name?) : Statement
      expect(TokenKind::Table)
      if_not_exists = parse_if_not_exists
      schema, name = parse_qualified_name
      if temporary && schema && !schema.same?("temp")
        action_error("temporary table name must be unqualified")
      end
      check_object_name(name)
      if accept(TokenKind::As)
        query = parse_select
        return CreateTable.new(temporary, if_not_exists, schema, name, [] of ColumnDefinition,
          [] of TableConstraint, [] of TableOption, query)
      end
      expect(TokenKind::LeftParen)
      table = TableUnderConstruction.new(name.value)
      columns = [] of ColumnDefinition
      constraints = [] of TableConstraint
      loop do
        columns << parse_column_definition(table)
        break unless accept(TokenKind::Comma)
        if table_constraint_start?
          constraints = parse_table_constraints(table)
          break
        end
      end
      expect(TokenKind::RightParen)
      options = parse_table_options
      CreateTable.new(temporary, if_not_exists, schema, name, columns, constraints, options, nil)
    end

    private def parse_if_not_exists : Bool
      return false unless kind.if?
      advance
      expect(TokenKind::Not)
      expect(TokenKind::Exists)
      true
    end

    # build.c, sqlite3CheckObjectName: names starting with sqlite_ are
    # reserved.
    private def check_object_name(name : Name) : Nil
      if name.value.size >= 7 && name.value[0, 7].compare("sqlite_", case_insensitive: true) == 0
        action_error("object name reserved for internal use: #{name.value}")
      end
    end

    private def table_constraint_start? : Bool
      kind.constraint? || kind.primary? || kind.unique? || kind.check? || kind.foreign?
    end

    private def parse_table_options : Array(TableOption)
      options = [] of TableOption
      return options unless kind.without? || nm?
      loop do
        if accept(TokenKind::Without)
          name = parse_nm
          action_error("unknown table option: #{name.text}") unless name.text.compare("rowid", case_insensitive: true) == 0
          options << TableOption.new(true, name)
        else
          name = parse_nm
          action_error("unknown table option: #{name.text}") unless name.text.compare("strict", case_insensitive: true) == 0
          options << TableOption.new(false, name)
        end
        break unless accept(TokenKind::Comma)
      end
      options
    end

    # `name [type] [constraint]...`, added to *table* as build.c's
    # sqlite3AddColumn does.
    private def parse_column_definition(table : TableUnderConstruction) : ColumnDefinition
      name = parse_nm
      type_name = parse_type_name
      if table.column_names.size + 1 > Limits::MAX_COLUMNS
        action_error("too many columns on #{table.name}")
      end
      if table.column_index(name.value)
        action_error("duplicate column name: #{name.value}")
      end
      table.column_names << name.value
      index = table.column_names.size - 1
      table.integer_columns << index if integer_type?(type_name)
      ColumnDefinition.new(name, type_name, parse_column_constraints(table, index))
    end

    # True when the declared type is exactly INTEGER, once a trailing
    # "GENERATED ALWAYS" the type absorbed is removed (build.c,
    # sqlite3AddColumn).
    private def integer_type?(type_name : TypeName?) : Bool
      return false unless type_name
      return false unless type_name.arguments.empty?
      words = type_name.words.map(&.text)
      if words.size >= 2 && words.last.compare("always", case_insensitive: true) == 0
        words.pop
        words.pop if words.last.compare("generated", case_insensitive: true) == 0
      end
      return false unless words.size == 1
      word = words.first
      word = word[1, word.size - 2] if word.size >= 2 && word[0].in?('"', '\'', '`', '[') && !word[1, word.size - 2].each_char.any?(&.in?('"', '\'', '`', '[', ']'))
      word.compare("INTEGER", case_insensitive: true) == 0
    end

    private def parse_column_constraints(table : TableUnderConstruction, column : Int32) : Array(ColumnConstraint)
      constraints = [] of ColumnConstraint
      loop do
        constraint = parse_column_constraint(table, column)
        break unless constraint
        constraints << constraint
      end
      constraints
    end

    private def parse_column_constraint(table : TableUnderConstruction, column : Int32) : ColumnConstraint?
      case kind
      when .constraint?
        advance
        ConstraintName.new(parse_nm)
      when .default?
        parse_default(table, column)
      when .null?
        advance
        NullConstraint.new(parse_on_conflict)
      when .not?
        if kind(1).null?
          advance
          advance
          NotNullConstraint.new(parse_on_conflict)
        else
          DeferrableConstraint.new(parse_deferrability)
        end
      when .primary?
        advance
        expect(TokenKind::Key)
        order = SortOrder::None
        if accept(TokenKind::Asc)
          order = SortOrder::Asc
        elsif accept(TokenKind::Desc)
          order = SortOrder::Desc
        end
        conflict = parse_on_conflict
        autoincrement = accept(TokenKind::Autoincrement)
        add_primary_key(table, [column], order.desc?, autoincrement)
        if !table.integer_columns.includes?(column) || order.desc?
          add_key_index(table, [column], ["binary"], conflict)
        end
        PrimaryKeyColumnConstraint.new(order, conflict, autoincrement)
      when .unique?
        advance
        conflict = parse_on_conflict
        add_key_index(table, [column], ["binary"], conflict)
        UniqueColumnConstraint.new(conflict)
      when .check?
        advance
        expect(TokenKind::LeftParen)
        expression = parse_expression
        expect(TokenKind::RightParen)
        CheckColumnConstraint.new(expression)
      when .references?
        clause = parse_foreign_key_clause
        if columns = clause.columns
          if columns.size != 1
            action_error("foreign key on #{table.column_names[column]} should reference only one column of table #{clause.table.text}")
          end
        end
        ReferencesConstraint.new(clause)
      when .deferrable?
        DeferrableConstraint.new(parse_deferrability)
      when .collate?
        advance
        CollateConstraint.new(parse_ids)
      when .generated?
        advance
        expect(TokenKind::Always)
        expect(TokenKind::As)
        parse_generated(table, column, generated_always: true)
      when TokenKind::As
        advance
        parse_generated(table, column, generated_always: false)
      end
    end

    # `DEFAULT literal`, `DEFAULT +|- literal`, `DEFAULT (expression)` or
    # `DEFAULT identifier` (parse.y ccons), checked as build.c's
    # sqlite3AddDefaultValue does.
    private def parse_default(table : TableUnderConstruction, column : Int32) : ColumnConstraint
      expect(TokenKind::Default)
      form = DefaultForm::Literal
      value = case kind
              when .left_paren?
                advance
                expression = parse_expression
                expect(TokenKind::RightParen)
                form = DefaultForm::Parenthesized
                expression
              when .plus?, .minus?
                operator = advance.kind.minus? ? UnaryOperator::Negate : UnaryOperator::Plus
                UnaryOperation.new(operator, parse_default_term)
              else
                if default_term_start?
                  parse_default_term
                elsif identifier_kind?(kind) || kind.indexed?
                  form = DefaultForm::Identifier
                  ColumnReference.new(nil, nil, name_of(advance))
                else
                  syntax_error
                end
              end
      if form.parenthesized? && !constant?(value)
        action_error("default value of column [#{table.column_names[column]}] is not constant")
      end
      if table.generated_columns.includes?(column)
        action_error("cannot use DEFAULT on a generated column")
      end
      table.defaulted_columns << column
      DefaultConstraint.new(value, form)
    end

    private def default_term_start? : Bool
      kind.null? || kind.float? || kind.blob? || kind.string? || kind.integer? ||
        kind.current_time_keyword? || kind.quoted_number?
    end

    # parse.y's term: a literal or CURRENT_TIME/DATE/TIMESTAMP.
    private def parse_default_term : Expression
      syntax_error unless default_term_start?
      if kind.string?
        return Literal.new(LiteralKind::String, text(advance))
      end
      parse_primary
    end

    # expr.c, sqlite3ExprIsConstantOrFunction outside a schema reparse: no
    # column (TRUE and FALSE excepted), parameter, subquery or window.
    private def constant?(expression : Expression) : Bool
      case expression
      when ColumnReference
        expression.table.nil? && (expression.column.same?("true") || expression.column.same?("false")) &&
          !expression.column.text.starts_with?('"') && !expression.column.text.starts_with?('`') &&
          !expression.column.text.starts_with?('[')
      when Parameter, ScalarSubquery, Exists, InSelect, InTable, Raise
        false
      when Literal
        true
      when UnaryOperation then constant?(expression.operand)
      when BinaryOperation
        constant?(expression.left) && constant?(expression.right)
      when LikeOperation
        constant?(expression.operand) && constant?(expression.pattern) &&
          ((escape = expression.escape).nil? || constant?(escape))
      when NullTest then constant?(expression.operand)
      when Between
        constant?(expression.operand) && constant?(expression.low) && constant?(expression.high)
      when InList
        constant?(expression.operand) && expression.values.all? { |value| constant?(value) }
      when CaseExpression
        ((operand = expression.operand).nil? || constant?(operand)) &&
          expression.branches.all? { |branch| constant?(branch.condition) && constant?(branch.result) } &&
          ((else_result = expression.else_result).nil? || constant?(else_result))
      when Cast    then constant?(expression.operand)
      when Collate then constant?(expression.operand)
      when FunctionCall
        expression.over.nil? && expression.over_name.nil? && expression.arguments.all? { |argument| constant?(argument) }
      when RowValue then expression.elements.all? { |element| constant?(element) }
      else
        true
      end
    end

    # `AS (expression) [STORED|VIRTUAL]` (build.c, sqlite3AddGenerated).
    private def parse_generated(table : TableUnderConstruction, column : Int32, generated_always : Bool) : ColumnConstraint
      expect(TokenKind::LeftParen)
      expression = parse_expression
      expect(TokenKind::RightParen)
      storage = nil
      if identifier_kind?(kind)
        storage = name_of(advance)
      end
      column_name = table.column_names[column]
      if table.defaulted_columns.includes?(column)
        action_error(%(error in generated column "#{column_name}"))
      end
      if storage && !(storage.text.compare("virtual", case_insensitive: true) == 0 ||
         storage.text.compare("stored", case_insensitive: true) == 0)
        action_error(%(error in generated column "#{column_name}"))
      end
      table.generated_columns << column
      if table.primary_key_columns.includes?(column)
        action_error("generated columns cannot be part of the PRIMARY KEY")
      end
      GeneratedConstraint.new(expression, storage, generated_always)
    end

    # build.c, sqlite3AddPrimaryKey.
    private def add_primary_key(table : TableUnderConstruction, columns : Array(Int32), descending : Bool,
                                autoincrement : Bool) : Nil
      if table.has_primary_key?
        action_error(%(table "#{table.name}" has more than one primary key))
      end
      table.mark_primary_key
      columns.each do |column|
        if table.generated_columns.includes?(column)
          action_error("generated columns cannot be part of the PRIMARY KEY")
        end
        table.primary_key_columns << column
      end
      integer_key = columns.size == 1 && table.integer_columns.includes?(columns.first) && !descending
      if autoincrement && !integer_key
        action_error("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY")
      end
    end

    # build.c, sqlite3AddPrimaryKey for a table constraint. The sort order
    # of the terms does not matter here.
    private def add_table_primary_key(table : TableUnderConstruction, columns : Array(OrderingTerm), autoincrement : Bool,
                                      conflict : ConflictResolution?) : Nil
      if table.has_primary_key?
        action_error(%(table "#{table.name}" has more than one primary key))
      end
      table.mark_primary_key
      last_column = nil
      columns.each do |term|
        if index = key_column_index(table, term.expression)
          if table.generated_columns.includes?(index)
            action_error("generated columns cannot be part of the PRIMARY KEY")
          end
          table.primary_key_columns << index
          last_column = index
        end
      end
      if columns.size == 1 && last_column && table.integer_columns.includes?(last_column)
        check_no_explicit_nulls(columns)
        return
      end
      action_error("AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY") if autoincrement
      check_key_columns(table, columns)
      add_term_index(table, columns, conflict)
    end

    private def add_term_index(table : TableUnderConstruction, columns : Array(OrderingTerm), conflict : ConflictResolution?) : Nil
      indexes = [] of Int32
      collations = [] of String
      columns.each do |term|
        expression = term.expression
        collation = "binary"
        if expression.is_a?(Collate)
          collation = expression.collation.value.downcase
          expression = expression.operand
        end
        index = key_column_index(table, expression)
        return unless index
        indexes << index
        collations << collation
      end
      add_key_index(table, indexes, collations, conflict)
    end

    # build.c, sqlite3CreateIndex: two constraint indexes on the same columns
    # may not name different conflict resolutions.
    private def add_key_index(table : TableUnderConstruction, columns : Array(Int32), collations : Array(String),
                              conflict : ConflictResolution?) : Nil
      table.key_indexes.each do |existing_columns, existing_collations, existing_conflict|
        next unless existing_columns == columns && existing_collations == collations
        if conflict && existing_conflict && conflict != existing_conflict
          action_error("conflicting ON CONFLICT clauses specified")
        end
      end
      table.key_indexes << {columns, collations, conflict}
    end

    private def parse_table_constraints(table : TableUnderConstruction) : Array(TableConstraint)
      constraints = [] of TableConstraint
      loop do
        constraints << parse_table_constraint(table)
        accept(TokenKind::Comma)
        break unless table_constraint_start?
      end
      constraints
    end

    private def parse_table_constraint(table : TableUnderConstruction) : TableConstraint
      case kind
      when .constraint?
        advance
        TableConstraintName.new(parse_nm)
      when .primary?
        advance
        expect(TokenKind::Key)
        expect(TokenKind::LeftParen)
        columns = parse_ordering_terms
        autoincrement = accept(TokenKind::Autoincrement)
        expect(TokenKind::RightParen)
        conflict = parse_on_conflict
        add_table_primary_key(table, columns, autoincrement, conflict)
        PrimaryKeyTableConstraint.new(columns, autoincrement, conflict)
      when .unique?
        advance
        expect(TokenKind::LeftParen)
        columns = parse_ordering_terms
        expect(TokenKind::RightParen)
        conflict = parse_on_conflict
        check_key_columns(table, columns)
        add_term_index(table, columns, conflict)
        UniqueTableConstraint.new(columns, conflict)
      when .check?
        advance
        expect(TokenKind::LeftParen)
        expression = parse_expression
        expect(TokenKind::RightParen)
        CheckTableConstraint.new(expression, parse_on_conflict)
      when .foreign?
        advance
        expect(TokenKind::Key)
        columns = parse_eidlist
        clause = parse_foreign_key_clause
        if (target_columns = clause.columns) && target_columns.size != columns.size
          action_error("number of columns in foreign key does not match the number of columns in the referenced table")
        end
        columns.each do |column|
          unless table.column_index(column.value)
            action_error(%(unknown column "#{column.value}" in foreign key definition))
          end
        end
        ForeignKeyTableConstraint.new(columns, clause)
      else
        syntax_error
      end
    end

    # The table column a PRIMARY KEY term names (a bare or quoted name,
    # after any COLLATE), as sqlite3AddPrimaryKey looks it up.
    private def key_column_index(table : TableUnderConstruction, expression : Expression) : Int32?
      expression = expression.operand if expression.is_a?(Collate)
      if expression.is_a?(ColumnReference) && expression.table.nil?
        table.column_index(expression.column.value)
      elsif expression.is_a?(Literal) && expression.kind.string?
        table.column_index(Parser.dequote(expression.text))
      end
    end

    # build.c, sqlite3CreateIndex on the table being built: every term of a
    # PRIMARY KEY or UNIQUE constraint is a column of the table.
    # build.c, sqlite3HasExplicitNulls: NULLS FIRST or LAST has no meaning in
    # a PRIMARY KEY or UNIQUE constraint.
    private def check_no_explicit_nulls(columns : Array(OrderingTerm)) : Nil
      columns.each do |term|
        next if term.nulls.none?
        big_nulls = term.order.desc? ? term.nulls.first? : term.nulls.last?
        flags = (term.order.desc? ? 1 : 0) | (big_nulls ? 2 : 0)
        action_error("unsupported use of NULLS #{flags == 0 || flags == 3 ? "FIRST" : "LAST"}")
      end
    end

    private def check_key_columns(table : TableUnderConstruction, columns : Array(OrderingTerm)) : Nil
      check_no_explicit_nulls(columns)
      columns.each do |term|
        expression = term.expression
        expression = expression.operand if expression.is_a?(Collate)
        name = if expression.is_a?(ColumnReference) && expression.table.nil?
                 expression.column.value
               elsif expression.is_a?(Literal) && expression.kind.string?
                 Parser.dequote(expression.text)
               end
        if name
          next if table.column_index(name) || name.compare("rowid", case_insensitive: true) == 0
          action_error("no such column: #{name}")
        end
        action_error("expressions prohibited in PRIMARY KEY and UNIQUE constraints")
      end
    end

    # `REFERENCES table [(columns)] [ON DELETE|UPDATE|INSERT action | MATCH name]...`.
    private def parse_foreign_key_clause : ForeignKeyClause
      expect(TokenKind::References)
      table = parse_nm
      columns = kind.left_paren? ? parse_eidlist : nil
      actions = [] of ForeignKeyAction
      match_names = [] of Name
      loop do
        if accept(TokenKind::Match)
          match_names << parse_nm
        elsif kind.on? && (kind(1).delete? || kind(1).update? || kind(1).insert?)
          advance
          event = text(advance).upcase
          actions << ForeignKeyAction.new(event, parse_foreign_key_action)
        else
          break
        end
      end
      deferrability = nil
      if kind.deferrable? || (kind.not? && kind(1).deferrable?)
        deferrability = parse_deferrability
      end
      ForeignKeyClause.new(table, columns, actions, match_names, deferrability)
    end

    private def parse_foreign_key_action : String
      case kind
      when .set?
        advance
        if accept(TokenKind::Null)
          "SET NULL"
        else
          expect(TokenKind::Default)
          "SET DEFAULT"
        end
      when .cascade?  then advance; "CASCADE"
      when .restrict? then advance; "RESTRICT"
      when .no?
        advance
        expect(TokenKind::Action)
        "NO ACTION"
      else
        syntax_error
      end
    end

    # `[NOT] DEFERRABLE [INITIALLY DEFERRED|IMMEDIATE]`.
    private def parse_deferrability : Deferrability
      negated = accept(TokenKind::Not)
      expect(TokenKind::Deferrable)
      initially = nil
      if accept(TokenKind::Initially)
        if accept(TokenKind::Deferred)
          initially = "DEFERRED"
        else
          expect(TokenKind::Immediate)
          initially = "IMMEDIATE"
        end
      end
      Deferrability.new(negated, initially)
    end
  end
end
