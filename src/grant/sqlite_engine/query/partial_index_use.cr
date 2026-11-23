module Grant::SQLiteEngine::Query
  # When the planner may read a table through a partial index
  # (whereUsablePartialIndex): every AND term of the index's WHERE must be
  # implied by some WHERE term of the query, where implied means
  # sqlite3ExprImpliesExpr's cases: the same expression, one side of an OR,
  # or `x IS NOT NULL` after a comparison that is false or NULL when x is
  # NULL (exprImpliesNotNull).
  module PartialIndexUse
    # The WHERE of each partial index, parsed once per CREATE INDEX text.
    @@where_by_sql = {} of String => SQL::Expression?
    @@lock = Mutex.new

    def self.where_of(layout : IndexLayout) : SQL::Expression?
      sql = layout.entry.sql
      return unless sql && layout.partial?
      @@lock.synchronize do
        return @@where_by_sql[sql] if @@where_by_sql.has_key?(sql)
        statement = SQL::Parser.parse_schema(sql)
        @@where_by_sql[sql] = statement.is_a?(SQL::CreateIndex) ? statement.where : nil
      end
    end

    # Whether some term of *terms* lets the planner use the partial index
    # *layout* on the table *entry* reads.
    def self.usable?(layout : IndexLayout, entry : FromEntry, terms : Array(Expr)) : Bool
      where = where_of(layout)
      return false unless where
      table = entry.table
      return false unless table
      conjuncts(where).all? do |part|
        terms.any? { |term| implies?(term, part, entry, table) }
      end
    end

    private def self.conjuncts(expression : SQL::Expression, into = [] of SQL::Expression) : Array(SQL::Expression)
      if expression.is_a?(SQL::BinaryOperation) && expression.operator.and?
        conjuncts(expression.left, into)
        conjuncts(expression.right, into)
      else
        into << expression
      end
      into
    end

    # sqlite3ExprImpliesExpr(term, part).
    def self.implies?(term : Expr, part : SQL::Expression, entry : FromEntry, table : TableInfo) : Bool
      return true if same?(term, part, entry, table)
      if part.is_a?(SQL::BinaryOperation) && part.operator.or?
        return implies?(term, part.left, entry, table) || implies?(term, part.right, entry, table)
      end
      if operand = not_null_operand(part)
        return implies_not_null?(term, operand, entry, table, false)
      end
      false
    end

    # The operand of `x IS NOT NULL` / `x NOTNULL` (TK_NOTNULL after
    # binaryToUnaryIfNull), or nil.
    private def self.not_null_operand(part : SQL::Expression) : SQL::Expression?
      if part.is_a?(SQL::NullTest)
        return part.operand unless part.form.is_null_keyword?
      elsif part.is_a?(SQL::BinaryOperation) && (part.operator.is_not? || part.operator.is_distinct_from?) && null_literal?(part.right)
        return part.left
      end
      nil
    end

    private def self.null_operand(part : SQL::Expression) : SQL::Expression?
      if part.is_a?(SQL::NullTest)
        return part.operand if part.form.is_null_keyword?
      elsif part.is_a?(SQL::BinaryOperation) && (part.operator.is? || part.operator.is_not_distinct_from?) && null_literal?(part.right)
        return part.left
      end
      nil
    end

    private def self.null_literal?(expression : SQL::Expression) : Bool
      expression.is_a?(SQL::Literal) && expression.kind.null?
    end

    # exprImpliesNotNull: *term* is false or NULL whenever *operand* is NULL.
    private def self.implies_not_null?(term : Expr, operand : SQL::Expression, entry : FromEntry, table : TableInfo,
                                       seen_not : Bool) : Bool
      return true if same?(term, operand, entry, table)
      case term
      when InListExpr
        return implies_not_null?(term.operand, operand, entry, table, true)
      when LogicalExpr
        return false unless term.between?
        return false if seen_not
        low = term.left.as?(ComparisonExpr)
        high = term.right.as?(ComparisonExpr)
        return false unless low && high
        return true if implies_not_null?(low.right, operand, entry, table, true) || implies_not_null?(high.right, operand, entry, table, true)
        implies_not_null?(low.left, operand, entry, table, true)
      when ComparisonExpr
        return false if term.operator.is? || term.operator.is_not?
        implies_not_null?(term.right, operand, entry, table, true) || implies_not_null?(term.left, operand, entry, table, true)
      when ArithmeticExpr, ConcatExpr, BitwiseExpr
        children = term.children
        return false unless children.size == 2
        implies_not_null?(children[1], operand, entry, table, true) || implies_not_null?(children[0], operand, entry, table, true)
      when NotExpr, BitNotExpr
        implies_not_null?(term.children.first, operand, entry, table, true)
      when CollateExpr, UnaryPlusExpr, NegateExpr
        implies_not_null?(term.children.first, operand, entry, table, seen_not)
      else
        false
      end
    end

    private def self.comparison_for(operator : SQL::BinaryOperator) : ComparisonOperator?
      case operator
      when .equal?, .double_equal?      then ComparisonOperator::Equal
      when .not_equal?, .less_greater?  then ComparisonOperator::NotEqual
      when .less?                       then ComparisonOperator::Less
      when .less_or_equal?              then ComparisonOperator::LessOrEqual
      when .greater?                    then ComparisonOperator::Greater
      when .greater_or_equal?           then ComparisonOperator::GreaterOrEqual
      when .is?, .is_not_distinct_from? then ComparisonOperator::Is
      when .is_not?, .is_distinct_from? then ComparisonOperator::IsNot
      end
    end

    # sqlite3ExprCompare(term, part) == 0 for the forms a partial index's
    # WHERE takes: columns of the table, literals, NULL tests and
    # comparisons of those.
    def self.same?(term : Expr, part : SQL::Expression, entry : FromEntry, table : TableInfo) : Bool
      case part
      when SQL::ColumnReference
        return false if part.schema
        if qualifier = part.table
          return false unless qualifier.value.compare(table.name, case_insensitive: true) == 0
        end
        position = table.column_index(part.column.value)
        if position
          return term.is_a?(ColumnExpr) && term.slot == entry.slot && term.column == position
        end
        term.is_a?(RowidExpr) && term.slot == entry.slot && RowidName.rowid?(table, part.column.value)
      when SQL::Literal
        return false unless term.is_a?(ConstantExpr)
        literal_equal?(term.value, part)
      when SQL::NullTest, SQL::BinaryOperation
        if operand = not_null_operand(part)
          return null_test_on?(term, operand, entry, table, negated: true)
        end
        if operand = null_operand(part)
          return null_test_on?(term, operand, entry, table, negated: false)
        end
        return false unless part.is_a?(SQL::BinaryOperation)
        operator = comparison_for(part.operator)
        return false unless operator && term.is_a?(ComparisonExpr) && term.operator == operator
        same?(term.left, part.left, entry, table) && same?(term.right, part.right, entry, table)
      else
        false
      end
    end

    private def self.null_test_on?(term : Expr, operand : SQL::Expression, entry : FromEntry, table : TableInfo, negated : Bool) : Bool
      if term.is_a?(NullTestExpr)
        return term.negated? == negated && same?(term.operand, operand, entry, table)
      end
      if term.is_a?(ComparisonExpr) && term.operator == (negated ? ComparisonOperator::IsNot : ComparisonOperator::Is)
        right = term.right
        return right.is_a?(ConstantExpr) && right.value.nil? && same?(term.left, operand, entry, table)
      end
      false
    end

    # A literal of the index's WHERE and a constant of the query are the
    # same token (TK_INTEGER and TK_STRING compare by text in C, so 1 and
    # '1' differ, as do 1 and 1.0).
    private def self.literal_equal?(value : Value, literal : SQL::Literal) : Bool
      kind = literal.kind
      case value
      when Nil     then kind.null?
      when Int64   then kind.integer? && NumericText.atoi64(literal.text).value == value && NumericText.atoi64(literal.text).code == 0
      when Float64 then kind.float? && NumericText.ato_f(literal.text).value == value
      when String  then kind.string? && SQL::Parser.dequote(literal.text) == value
      else              false
      end
    end
  end
end
