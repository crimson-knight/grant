module Grant::SQLiteEngine::SQL
  # Writes a syntax tree back as SQL text. Names, literals and parameters
  # are written as they were in the source; every operand that is itself an
  # operation is parenthesized, so the text parses back to an equal tree
  # whatever the operators' precedence.
  class Printer
    def initialize(@io : IO)
    end

    def print(node : Node) : Nil
      write(node)
    end

    # ------------------------------------------------------------- helpers

    private def name(value : Name) : Nil
      @io << value.text
    end

    private def qualified(schema : Name?, value : Name) : Nil
      if schema
        name(schema)
        @io << '.'
      end
      name(value)
    end

    private def list(items : Enumerable, separator : String = ", ", &) : Nil
      items.each_with_index do |item, index|
        @io << separator if index > 0
        yield item
      end
    end

    private def names(values : Array(Name)) : Nil
      list(values) { |value| name(value) }
    end

    private def expressions(values : Array(Expression)) : Nil
      list(values) { |value| write(value) }
    end

    # An operand: written bare when it is a single term, parenthesized when
    # it is an operation.
    private def operand(expression : Expression) : Nil
      case expression
      when Literal, Parameter, ColumnReference, FunctionCall, ScalarSubquery, Exists, CaseExpression,
           Cast, RowValue, Raise
        write(expression)
      else
        @io << '('
        write(expression)
        @io << ')'
      end
    end

    private def conflict(resolution : ConflictResolution) : Nil
      @io << resolution.to_s.upcase
    end

    private def on_conflict(resolution : ConflictResolution?) : Nil
      return unless resolution
      @io << " ON CONFLICT "
      conflict(resolution)
    end

    private def ordering_terms(terms : Array(OrderingTerm)) : Nil
      list(terms) { |term| write(term) }
    end

    # ---------------------------------------------------------- expressions

    private def write(node : Literal) : Nil
      @io << node.text
    end

    private def write(node : Parameter) : Nil
      @io << node.text
    end

    private def write(node : ColumnReference) : Nil
      if schema = node.schema
        name(schema)
        @io << '.'
      end
      if table = node.table
        name(table)
        @io << '.'
      end
      name(node.column)
    end

    private def write(node : UnaryOperation) : Nil
      case node.operator
      when .negate?  then @io << '-'
      when .plus?    then @io << '+'
      when .not?     then @io << "NOT "
      when .bit_not? then @io << '~'
      end
      operand(node.operand)
    end

    BINARY_TEXT = {
      BinaryOperator::Or => "OR", BinaryOperator::And => "AND", BinaryOperator::Equal => "=",
      BinaryOperator::DoubleEqual => "==", BinaryOperator::NotEqual => "!=", BinaryOperator::LessGreater => "<>",
      BinaryOperator::Less => "<", BinaryOperator::LessOrEqual => "<=", BinaryOperator::Greater => ">",
      BinaryOperator::GreaterOrEqual => ">=", BinaryOperator::Is => "IS", BinaryOperator::IsNot => "IS NOT",
      BinaryOperator::IsDistinctFrom => "IS DISTINCT FROM", BinaryOperator::IsNotDistinctFrom => "IS NOT DISTINCT FROM",
      BinaryOperator::BitAnd => "&", BinaryOperator::BitOr => "|", BinaryOperator::ShiftLeft => "<<",
      BinaryOperator::ShiftRight => ">>", BinaryOperator::Add => "+", BinaryOperator::Subtract => "-",
      BinaryOperator::Multiply => "*", BinaryOperator::Divide => "/", BinaryOperator::Remainder => "%",
      BinaryOperator::Concat => "||", BinaryOperator::Extract => "->", BinaryOperator::ExtractText => "->>",
    }

    private def write(node : BinaryOperation) : Nil
      operand(node.left)
      @io << ' ' << BINARY_TEXT[node.operator] << ' '
      operand(node.right)
    end

    private def write(node : LikeOperation) : Nil
      operand(node.operand)
      @io << (node.negated ? " NOT " : " ") << node.operator << ' '
      operand(node.pattern)
      if escape = node.escape
        @io << " ESCAPE "
        operand(escape)
      end
    end

    private def write(node : NullTest) : Nil
      operand(node.operand)
      case node.form
      when .is_null_keyword?  then @io << " ISNULL"
      when .not_null_keyword? then @io << " NOTNULL"
      else                         @io << " NOT NULL"
      end
    end

    private def write(node : Between) : Nil
      operand(node.operand)
      @io << (node.negated ? " NOT BETWEEN " : " BETWEEN ")
      operand(node.low)
      @io << " AND "
      operand(node.high)
    end

    private def write(node : InList) : Nil
      operand(node.operand)
      @io << (node.negated ? " NOT IN (" : " IN (")
      expressions(node.values)
      @io << ')'
    end

    private def write(node : InSelect) : Nil
      operand(node.operand)
      @io << (node.negated ? " NOT IN (" : " IN (")
      write(node.query)
      @io << ')'
    end

    private def write(node : InTable) : Nil
      operand(node.operand)
      @io << (node.negated ? " NOT IN " : " IN ")
      qualified(node.schema, node.table)
      if arguments = node.arguments
        @io << '('
        expressions(arguments)
        @io << ')'
      end
    end

    private def write(node : Exists) : Nil
      @io << "EXISTS ("
      write(node.query)
      @io << ')'
    end

    private def write(node : ScalarSubquery) : Nil
      @io << '('
      write(node.query)
      @io << ')'
    end

    private def write(node : CaseExpression) : Nil
      @io << "CASE"
      if case_operand = node.operand
        @io << ' '
        operand(case_operand)
      end
      node.branches.each do |branch|
        @io << " WHEN "
        write(branch.condition)
        @io << " THEN "
        write(branch.result)
      end
      if else_result = node.else_result
        @io << " ELSE "
        write(else_result)
      end
      @io << " END"
    end

    private def write(node : Cast) : Nil
      @io << "CAST("
      write(node.operand)
      @io << " AS"
      if type_name = node.type_name
        @io << ' '
        write(type_name)
      end
      @io << ')'
    end

    private def write(node : Collate) : Nil
      operand(node.operand)
      @io << " COLLATE "
      name(node.collation)
    end

    private def write(node : OrderingTerm) : Nil
      write(node.expression)
      case node.order
      when .asc?  then @io << " ASC"
      when .desc? then @io << " DESC"
      end
      case node.nulls
      when .first? then @io << " NULLS FIRST"
      when .last?  then @io << " NULLS LAST"
      end
    end

    private def write(node : FunctionCall) : Nil
      name(node.name)
      @io << '('
      if node.star
        @io << '*'
      else
        case node.distinct
        when .distinct? then @io << "DISTINCT "
        when .all?      then @io << "ALL "
        end
        expressions(node.arguments)
        unless node.order_by.empty?
          @io << (node.arguments.empty? ? "ORDER BY " : " ORDER BY ")
          ordering_terms(node.order_by)
        end
      end
      @io << ')'
      if filter = node.filter
        @io << " FILTER (WHERE "
        write(filter)
        @io << ')'
      end
      if over = node.over
        @io << " OVER ("
        write(over)
        @io << ')'
      elsif over_name = node.over_name
        @io << " OVER "
        name(over_name)
      end
    end

    private def write(node : RowValue) : Nil
      @io << '('
      expressions(node.elements)
      @io << ')'
    end

    private def write(node : Raise) : Nil
      @io << "RAISE(" << node.action.to_s.upcase
      if message = node.message
        @io << ", "
        write(message)
      end
      @io << ')'
    end

    # --------------------------------------------------------------- windows

    private def write(node : Window) : Nil
      parts = [] of Proc(Nil)
      if base = node.base
        parts << -> { name(base); nil }
      end
      unless node.partition_by.empty?
        parts << -> { @io << "PARTITION BY "; expressions(node.partition_by); nil }
      end
      unless node.order_by.empty?
        parts << -> { @io << "ORDER BY "; ordering_terms(node.order_by); nil }
      end
      if frame = node.frame
        parts << -> { write(frame); nil }
      end
      list(parts, " ", &.call)
    end

    private def write(node : Frame) : Nil
      @io << node.unit.to_s.upcase << ' '
      if finish = node.finish
        @io << "BETWEEN "
        write(node.start)
        @io << " AND "
        write(finish)
      else
        write(node.start)
      end
      case node.exclude
      when .no_others?   then @io << " EXCLUDE NO OTHERS"
      when .current_row? then @io << " EXCLUDE CURRENT ROW"
      when .group?       then @io << " EXCLUDE GROUP"
      when .ties?        then @io << " EXCLUDE TIES"
      end
    end

    private def write(node : FrameBound) : Nil
      case node.kind
      when .unbounded_preceding? then @io << "UNBOUNDED PRECEDING"
      when .unbounded_following? then @io << "UNBOUNDED FOLLOWING"
      when .current_row?         then @io << "CURRENT ROW"
      else
        if offset = node.offset
          write(offset)
        end
        @io << (node.kind.preceding? ? " PRECEDING" : " FOLLOWING")
      end
    end

    # ---------------------------------------------------------------- SELECT

    private def write(node : WithClause) : Nil
      @io << (node.recursive ? "WITH RECURSIVE " : "WITH ")
      list(node.tables) do |table|
        name(table.name)
        if columns = table.columns
          @io << " ("
          names(columns)
          @io << ')'
        end
        @io << " AS "
        case table.materialization
        when .materialized?     then @io << "MATERIALIZED "
        when .not_materialized? then @io << "NOT MATERIALIZED "
        end
        @io << '('
        write(table.query)
        @io << ')'
      end
    end

    private def write(node : SelectStatement) : Nil
      if with_clause = node.with_clause
        write(with_clause)
        @io << ' '
      end
      node.cores.each_with_index do |core, index|
        if index > 0
          @io << ' ' << compound_text(node.operators[index - 1]) << ' '
        end
        write(core)
      end
      unless node.order_by.empty?
        @io << " ORDER BY "
        ordering_terms(node.order_by)
      end
      if limit = node.limit
        @io << " LIMIT "
        if limit.comma_form
          if offset = limit.offset
            write(offset)
            @io << ", "
          end
          write(limit.count)
        else
          write(limit.count)
          if offset = limit.offset
            @io << " OFFSET "
            write(offset)
          end
        end
      end
    end

    private def compound_text(operator : CompoundOperator) : String
      case operator
      when .union_all? then "UNION ALL"
      when .intersect? then "INTERSECT"
      when .except?    then "EXCEPT"
      else                  "UNION"
      end
    end

    private def write(node : ValuesClause) : Nil
      @io << "VALUES "
      list(node.rows) do |row|
        @io << '('
        expressions(row)
        @io << ')'
      end
    end

    private def write(node : SelectClause) : Nil
      @io << "SELECT "
      case node.distinct
      when .distinct? then @io << "DISTINCT "
      when .all?      then @io << "ALL "
      end
      result_columns(node.columns)
      if from = node.from
        @io << " FROM "
        write(from)
      end
      if where = node.where
        @io << " WHERE "
        write(where)
      end
      unless node.group_by.empty?
        @io << " GROUP BY "
        expressions(node.group_by)
      end
      if having = node.having
        @io << " HAVING "
        write(having)
      end
      unless node.windows.empty?
        @io << " WINDOW "
        list(node.windows) do |definition|
          name(definition.name)
          @io << " AS ("
          write(definition.window)
          @io << ')'
        end
      end
    end

    private def result_columns(columns : Array(ResultColumn)) : Nil
      list(columns) do |column|
        case column
        when AllColumns
          if table = column.table
            name(table)
            @io << '.'
          end
          @io << '*'
        when ExpressionColumn
          write(column.expression)
          if alias_name = column.alias_name
            @io << " AS "
            name(alias_name)
          end
        end
      end
    end

    private def write(node : From) : Nil
      node.items.each do |item|
        if join = item.join
          if join.comma
            @io << ", "
          else
            @io << ' '
            join.keywords.each { |word| @io << word << ' ' }
            @io << "JOIN "
          end
        end
        write(item.source)
        if on = item.on
          @io << " ON "
          write(on)
        elsif using = item.using
          @io << " USING ("
          names(using)
          @io << ')'
        end
      end
    end

    private def alias_clause(alias_name : Name?) : Nil
      return unless alias_name
      @io << " AS "
      name(alias_name)
    end

    private def write(node : TableReference) : Nil
      qualified(node.schema, node.name)
      alias_clause(node.alias_name)
      if indexed_by = node.indexed_by
        @io << " INDEXED BY "
        name(indexed_by)
      elsif node.not_indexed
        @io << " NOT INDEXED"
      end
    end

    private def write(node : TableFunction) : Nil
      qualified(node.schema, node.name)
      @io << '('
      expressions(node.arguments)
      @io << ')'
      alias_clause(node.alias_name)
    end

    private def write(node : SubquerySource) : Nil
      @io << '('
      write(node.query)
      @io << ')'
      alias_clause(node.alias_name)
    end

    private def write(node : NestedJoin) : Nil
      @io << '('
      write(node.from)
      @io << ')'
      alias_clause(node.alias_name)
    end

    # ------------------------------------------------------------------- DML

    private def with_prefix(with_clause : WithClause?) : Nil
      return unless with_clause
      write(with_clause)
      @io << ' '
    end

    private def write(node : QualifiedTable) : Nil
      qualified(node.schema, node.name)
      alias_clause(node.alias_name)
    end

    private def returning(columns : Array(ResultColumn)?) : Nil
      return unless columns
      @io << " RETURNING "
      result_columns(columns)
    end

    private def assignments(values : Array(Assignment)) : Nil
      list(values) do |assignment|
        if assignment.parenthesized
          @io << '('
          names(assignment.columns)
          @io << ')'
        else
          name(assignment.columns.first)
        end
        @io << " = "
        write(assignment.value)
      end
    end

    private def indexed(indexed_by : Name?, not_indexed : Bool) : Nil
      if indexed_by
        @io << " INDEXED BY "
        name(indexed_by)
      elsif not_indexed
        @io << " NOT INDEXED"
      end
    end

    private def write(node : Insert) : Nil
      with_prefix(node.with_clause)
      if node.verb.replace?
        @io << "REPLACE"
      else
        @io << "INSERT"
        if resolution = node.conflict
          @io << " OR "
          conflict(resolution)
        end
      end
      @io << " INTO "
      write(node.table)
      if columns = node.columns
        @io << " ("
        names(columns)
        @io << ')'
      end
      if source = node.source
        @io << ' '
        write(source)
      else
        @io << " DEFAULT VALUES"
      end
      node.upserts.each do |upsert|
        @io << " ON CONFLICT"
        if target = upsert.target
          @io << " ("
          ordering_terms(target)
          @io << ')'
          if target_where = upsert.target_where
            @io << " WHERE "
            write(target_where)
          end
        end
        if values = upsert.assignments
          @io << " DO UPDATE SET "
          assignments(values)
          if where = upsert.where
            @io << " WHERE "
            write(where)
          end
        else
          @io << " DO NOTHING"
        end
      end
      returning(node.returning)
    end

    private def write(node : Update) : Nil
      with_prefix(node.with_clause)
      @io << "UPDATE "
      if resolution = node.conflict
        @io << "OR "
        conflict(resolution)
        @io << ' '
      end
      write(node.table)
      indexed(node.indexed_by, node.not_indexed)
      @io << " SET "
      assignments(node.assignments)
      if from = node.from
        @io << " FROM "
        write(from)
      end
      if where = node.where
        @io << " WHERE "
        write(where)
      end
      returning(node.returning)
    end

    private def write(node : Delete) : Nil
      with_prefix(node.with_clause)
      @io << "DELETE FROM "
      write(node.table)
      indexed(node.indexed_by, node.not_indexed)
      if where = node.where
        @io << " WHERE "
        write(where)
      end
      returning(node.returning)
    end

    # ------------------------------------------------------------------- DDL

    private def write(node : TypeName) : Nil
      names_separated(node.words)
      unless node.arguments.empty?
        @io << '('
        list(node.arguments) { |argument| @io << argument }
        @io << ')'
      end
    end

    private def names_separated(values : Array(Name)) : Nil
      list(values, " ") { |value| name(value) }
    end

    private def write(node : ForeignKeyClause) : Nil
      @io << "REFERENCES "
      name(node.table)
      if columns = node.columns
        @io << " ("
        names(columns)
        @io << ')'
      end
      node.actions.each do |action|
        @io << " ON " << action.event << ' ' << action.action
      end
      node.match_names.each do |match_name|
        @io << " MATCH "
        name(match_name)
      end
      if deferrability = node.deferrability
        @io << ' '
        write(deferrability)
      end
    end

    private def write(node : Deferrability) : Nil
      @io << (node.negated ? "NOT DEFERRABLE" : "DEFERRABLE")
      if initially = node.initially
        @io << " INITIALLY " << initially
      end
    end

    private def write(node : ColumnDefinition) : Nil
      name(node.name)
      if type_name = node.type_name
        @io << ' '
        write(type_name)
      end
      node.constraints.each do |constraint|
        @io << ' '
        write(constraint)
      end
    end

    private def write(node : ConstraintName) : Nil
      @io << "CONSTRAINT "
      name(node.name)
    end

    private def write(node : PrimaryKeyColumnConstraint) : Nil
      @io << "PRIMARY KEY"
      case node.order
      when .asc?  then @io << " ASC"
      when .desc? then @io << " DESC"
      end
      on_conflict(node.conflict)
      @io << " AUTOINCREMENT" if node.autoincrement
    end

    private def write(node : NotNullConstraint) : Nil
      @io << "NOT NULL"
      on_conflict(node.conflict)
    end

    private def write(node : NullConstraint) : Nil
      @io << "NULL"
      on_conflict(node.conflict)
    end

    private def write(node : UniqueColumnConstraint) : Nil
      @io << "UNIQUE"
      on_conflict(node.conflict)
    end

    private def write(node : CheckColumnConstraint) : Nil
      @io << "CHECK ("
      write(node.expression)
      @io << ')'
    end

    private def write(node : DefaultConstraint) : Nil
      @io << "DEFAULT "
      case node.form
      when .parenthesized?
        @io << '('
        write(node.value)
        @io << ')'
      else
        write(node.value)
      end
    end

    private def write(node : CollateConstraint) : Nil
      @io << "COLLATE "
      name(node.collation)
    end

    private def write(node : ReferencesConstraint) : Nil
      write(node.clause)
    end

    private def write(node : DeferrableConstraint) : Nil
      write(node.deferrability)
    end

    private def write(node : GeneratedConstraint) : Nil
      @io << "GENERATED ALWAYS " if node.generated_always
      @io << "AS ("
      write(node.expression)
      @io << ')'
      if storage = node.storage
        @io << ' '
        name(storage)
      end
    end

    private def write(node : TableConstraintName) : Nil
      @io << "CONSTRAINT "
      name(node.name)
    end

    private def write(node : PrimaryKeyTableConstraint) : Nil
      @io << "PRIMARY KEY ("
      ordering_terms(node.columns)
      @io << " AUTOINCREMENT" if node.autoincrement
      @io << ')'
      on_conflict(node.conflict)
    end

    private def write(node : UniqueTableConstraint) : Nil
      @io << "UNIQUE ("
      ordering_terms(node.columns)
      @io << ')'
      on_conflict(node.conflict)
    end

    private def write(node : CheckTableConstraint) : Nil
      @io << "CHECK ("
      write(node.expression)
      @io << ')'
      on_conflict(node.conflict)
    end

    private def write(node : ForeignKeyTableConstraint) : Nil
      @io << "FOREIGN KEY ("
      names(node.columns)
      @io << ") "
      write(node.clause)
    end

    private def temporary_prefix(temporary : Name?) : Nil
      return unless temporary
      name(temporary)
      @io << ' '
    end

    private def if_not_exists(present : Bool) : Nil
      @io << "IF NOT EXISTS " if present
    end

    private def write(node : CreateTable) : Nil
      @io << "CREATE "
      temporary_prefix(node.temporary)
      @io << "TABLE "
      if_not_exists(node.if_not_exists)
      qualified(node.schema, node.name)
      if query = node.as_select
        @io << " AS "
        write(query)
        return
      end
      @io << " ("
      list(node.columns) { |column| write(column) }
      node.constraints.each_with_index do |constraint, index|
        # A comma after CONSTRAINT name would clear the name in SQLite.
        @io << (index > 0 && node.constraints[index - 1].is_a?(TableConstraintName) ? " " : ", ")
        write(constraint)
      end
      @io << ')'
      unless node.options.empty?
        @io << ' '
        list(node.options) do |option|
          @io << "WITHOUT " if option.without_rowid
          name(option.text)
        end
      end
    end

    private def write(node : CreateIndex) : Nil
      @io << (node.unique ? "CREATE UNIQUE INDEX " : "CREATE INDEX ")
      if_not_exists(node.if_not_exists)
      qualified(node.schema, node.name)
      @io << " ON "
      name(node.table)
      @io << " ("
      ordering_terms(node.columns)
      @io << ')'
      if where = node.where
        @io << " WHERE "
        write(where)
      end
    end

    private def write(node : CreateView) : Nil
      @io << "CREATE "
      temporary_prefix(node.temporary)
      @io << "VIEW "
      if_not_exists(node.if_not_exists)
      qualified(node.schema, node.name)
      if columns = node.columns
        @io << " ("
        names(columns)
        @io << ')'
      end
      @io << " AS "
      write(node.query)
    end

    private def write(node : CreateTrigger) : Nil
      @io << "CREATE "
      temporary_prefix(node.temporary)
      @io << "TRIGGER "
      if_not_exists(node.if_not_exists)
      qualified(node.schema, node.name)
      case node.time
      when .before?     then @io << " BEFORE"
      when .after?      then @io << " AFTER"
      when .instead_of? then @io << " INSTEAD OF"
      end
      @io << ' ' << node.event.to_s.upcase
      if columns = node.update_columns
        @io << " OF "
        names(columns)
      end
      @io << " ON "
      qualified(node.table_schema, node.table)
      @io << " FOR EACH ROW" if node.for_each_row
      if when_condition = node.when_condition
        @io << " WHEN "
        write(when_condition)
      end
      @io << " BEGIN "
      node.body.each do |statement|
        write(statement)
        @io << "; "
      end
      @io << "END"
    end

    private def write(node : CreateVirtualTable) : Nil
      @io << "CREATE VIRTUAL TABLE "
      if_not_exists(node.if_not_exists)
      qualified(node.schema, node.name)
      @io << " USING "
      name(node.module_name)
      if arguments = node.arguments
        @io << '('
        list(arguments) { |argument| @io << argument }
        @io << ')'
      end
    end

    private def write(node : Drop) : Nil
      @io << "DROP " << node.kind.to_s.upcase << ' '
      @io << "IF EXISTS " if node.if_exists
      qualified(node.schema, node.name)
    end

    private def write(node : AlterTable) : Nil
      @io << "ALTER TABLE "
      qualified(node.schema, node.table)
      action = node.action
      case action
      when RenameTable
        @io << " RENAME TO "
        name(action.new_name)
      when RenameColumn
        @io << (action.column_keyword ? " RENAME COLUMN " : " RENAME ")
        name(action.old_name)
        @io << " TO "
        name(action.new_name)
      when AddColumn
        @io << (action.column_keyword ? " ADD COLUMN " : " ADD ")
        write(action.column)
      when DropColumn
        @io << (action.column_keyword ? " DROP COLUMN " : " DROP ")
        name(action.column_name)
      end
    end

    # ------------------------------------------------------ the rest

    private def transaction_suffix(keyword : Bool, transaction_name : Name?) : Nil
      return unless keyword
      @io << " TRANSACTION"
      if transaction_name
        @io << ' '
        name(transaction_name)
      end
    end

    private def write(node : Begin) : Nil
      @io << "BEGIN"
      @io << ' ' << node.mode.to_s.upcase unless node.mode.none?
      transaction_suffix(node.transaction_keyword, node.transaction_name)
    end

    private def write(node : Commit) : Nil
      @io << node.keyword
      transaction_suffix(node.transaction_keyword, node.transaction_name)
    end

    private def write(node : Rollback) : Nil
      @io << "ROLLBACK"
      transaction_suffix(node.transaction_keyword, node.transaction_name)
      if savepoint = node.savepoint
        @io << (node.savepoint_keyword ? " TO SAVEPOINT " : " TO ")
        name(savepoint)
      end
    end

    private def write(node : Savepoint) : Nil
      @io << "SAVEPOINT "
      name(node.name)
    end

    private def write(node : Release) : Nil
      @io << (node.savepoint_keyword ? "RELEASE SAVEPOINT " : "RELEASE ")
      name(node.name)
    end

    private def write(node : Pragma) : Nil
      @io << "PRAGMA "
      qualified(node.schema, node.name)
      case node.form
      when .assignment? then @io << " = " << node.value
      when .call?       then @io << '(' << node.value << ')'
      end
    end

    private def write(node : Attach) : Nil
      @io << (node.database_keyword ? "ATTACH DATABASE " : "ATTACH ")
      write(node.file)
      @io << " AS "
      write(node.schema)
      if key = node.key
        @io << " KEY "
        write(key)
      end
    end

    private def write(node : Detach) : Nil
      @io << (node.database_keyword ? "DETACH DATABASE " : "DETACH ")
      write(node.schema)
    end

    private def write(node : Analyze) : Nil
      @io << "ANALYZE"
      if analyzed = node.name
        @io << ' '
        qualified(node.schema, analyzed)
      end
    end

    private def write(node : Reindex) : Nil
      @io << "REINDEX"
      if reindexed = node.name
        @io << ' '
        qualified(node.schema, reindexed)
      end
    end

    private def write(node : Vacuum) : Nil
      @io << "VACUUM"
      if schema = node.schema
        @io << ' '
        name(schema)
      end
      if into = node.into
        @io << " INTO "
        write(into)
      end
    end

    private def write(node : Explain) : Nil
      @io << (node.query_plan ? "EXPLAIN QUERY PLAN " : "EXPLAIN ")
      write(node.statement)
    end

    private def write(node : Node) : Nil
      raise ArgumentError.new("no SQL form for #{node.class}")
    end
  end
end
