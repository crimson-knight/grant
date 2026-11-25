module Grant::SQLiteEngine::Query
  # Compiles expressions: literals as SQLite reads them, names resolved by
  # lookupName's rules, operators with their affinity and collation,
  # functions, aggregates and subqueries.
  module ExpressionCompiler
    AGGREGATE_NAMES = %w[count sum total avg min max group_concat string_agg]
    ROWID_NAMES     = %w[rowid oid _rowid_]

    # True when *expression* calls an aggregate function outside any
    # subquery.
    def contains_aggregate?(expression : SQL::Expression) : Bool
      case expression
      when SQL::FunctionCall
        name = expression.name.value.downcase
        if expression.over.nil? && expression.over_name.nil? && AGGREGATE_NAMES.includes?(name)
          return true unless name.in?("min", "max") && expression.arguments.size != 1
        end
        expression.arguments.any? { |argument| contains_aggregate?(argument) } ||
          (expression.filter.try { |filter| contains_aggregate?(filter) } || false)
      when SQL::Exists, SQL::ScalarSubquery
        false
      else
        children_of(expression).any? { |child| contains_aggregate?(child) }
      end
    end

    # The sub-expressions of an expression, not entering subqueries.
    def children_of(expression : SQL::Expression) : Array(SQL::Expression)
      case expression
      when SQL::UnaryOperation  then [expression.operand] of SQL::Expression
      when SQL::BinaryOperation then [expression.left, expression.right] of SQL::Expression
      when SQL::LikeOperation
        list = [expression.operand, expression.pattern] of SQL::Expression
        if escape = expression.escape
          list << escape
        end
        list
      when SQL::NullTest then [expression.operand] of SQL::Expression
      when SQL::Between  then [expression.operand, expression.low, expression.high] of SQL::Expression
      when SQL::InList   then [expression.operand] + expression.values
      when SQL::InSelect then [expression.operand] of SQL::Expression
      when SQL::InTable  then [expression.operand] of SQL::Expression
      when SQL::Cast     then [expression.operand] of SQL::Expression
      when SQL::Collate  then [expression.operand] of SQL::Expression
      when SQL::RowValue then expression.elements
      when SQL::FunctionCall
        list = expression.arguments.dup
        if filter = expression.filter
          list << filter
        end
        list
      when SQL::CaseExpression
        list = [] of SQL::Expression
        if operand = expression.operand
          list << operand
        end
        expression.branches.each do |branch|
          list << branch.condition
          list << branch.result
        end
        if else_result = expression.else_result
          list << else_result
        end
        list
      else
        [] of SQL::Expression
      end
    end

    # An error resolveExprStep records and walks on past (it counts nNcErr):
    # sqlite3ErrorMsg keeps the last message, so of these the last one in
    # walk order is reported, a function's own error before its arguments'.
    CONTINUING_ERROR_PREFIXES = {"no such function", "wrong number of arguments", "misuse of aggregate"}

    # lookupName's errors end the walk of the expression (WRC_Abort), except
    # under IS NULL and NOT NULL, whose operand walk's result is ignored.
    LOOKUP_ERROR_PREFIXES = {"no such column", "ambiguous column name"}

    # Whether *error*'s message starts like one of `CONTINUING_ERROR_PREFIXES`.
    def self.continuing_error?(error : Exception) : Bool
      message = error.message || ""
      CONTINUING_ERROR_PREFIXES.any? { |prefix| message.starts_with?(prefix) }
    end

    # Whether *error*'s message starts like one of `LOOKUP_ERROR_PREFIXES`.
    def self.lookup_error?(error : Exception) : Bool
      message = error.message || ""
      LOOKUP_ERROR_PREFIXES.any? { |prefix| message.starts_with?(prefix) }
    end

    # Compiles one expression the way sqlite3ResolveExprNames walks it: name
    # errors are recorded and the walk goes on; the first one is raised.
    def resolve_expression(expression : SQL::Expression, context : QueryContext) : Expr
      saved = @list_of_name_errors
      errors = [] of SQLError
      @list_of_name_errors = errors
      begin
        compiled = compile_expression(expression, context)
      ensure
        @list_of_name_errors = saved
      end
      if last = errors.last?
        raise ResolveError.new(last.message || "SQL error", last.result_code)
      end
      compiled
    rescue ResolveAbort
      last = errors.try(&.last?)
      raise ResolveError.new(last.try(&.message) || "SQL error", last.try(&.result_code) || SQLError::ERROR)
    end

    # The walk of an expression stopped (WRC_Abort). It ends at the top of
    # the expression, at a function's argument list, or at the operand of
    # IS NULL and NOT NULL, whose walk results C ignores.
    class ResolveAbort < Exception
    end

    # resolveExprStep returns WRC_Abort for any node once pParse->nErr is
    # set, except the nodes it handles itself and prunes: column names
    # (lookupName), functions and IS NULL / NOT NULL.
    private def aborts_after_error?(expression : SQL::Expression) : Bool
      return false if expression.is_a?(SQL::ColumnReference) || expression.is_a?(SQL::FunctionCall) || expression.is_a?(SQL::NullTest)
      return false if null_comparison?(expression)
      return expression.negated if expression.is_a?(SQL::LikeOperation)
      true
    end

    # Records *error* when an expression is being resolved; false otherwise.
    private def record_name_error(error : SQLError) : Bool
      errors = @list_of_name_errors
      return false if errors.nil? || error.is_a?(ResolveError) || !ExpressionCompiler.continuing_error?(error)
      errors << error
      true
    end

    def compile_expression(expression : SQL::Expression, context : QueryContext) : Expr
      errors = @list_of_name_errors
      raise ResolveAbort.new if errors && !errors.empty? && aborts_after_error?(expression)
      compile_expression_node(expression, context)
    rescue error : SQLError
      if errors && !error.is_a?(ResolveError) && ExpressionCompiler.lookup_error?(error)
        errors << error
        raise ResolveAbort.new
      end
      raise error unless record_name_error(error)
      ConstantExpr.new(nil)
    end

    private def compile_expression_node(expression : SQL::Expression, context : QueryContext) : Expr
      case expression
      when SQL::Literal         then compile_literal(expression, negative: false)
      when SQL::Parameter       then ParameterExpr.new(expression.number)
      when SQL::ColumnReference then resolve_column(expression, context)
      when SQL::UnaryOperation  then compile_unary(expression, context)
      when SQL::BinaryOperation then compile_binary(expression, context)
      when SQL::LikeOperation   then compile_like(expression, context)
      when SQL::NullTest
        NullTestExpr.new(compile_null_test_operand(expression.operand, context), negated: !expression.form.is_null_keyword?)
      when SQL::Between
        operand = compile_expression(expression.operand, context)
        low = compile_comparison(ComparisonOperator::GreaterOrEqual, operand, compile_expression(expression.low, context))
        high = compile_comparison(ComparisonOperator::LessOrEqual, operand, compile_expression(expression.high, context))
        both = LogicalExpr.new(true, low, high)
        both.between = true
        expression.negated ? NotExpr.new(both) : both
      when SQL::InList   then compile_in_list(expression, context)
      when SQL::InSelect then compile_in_select(expression.operand, expression.query, expression.negated, context)
      when SQL::InTable
        raise UnsupportedSQL.new("IN with a table name on the right") if expression.arguments
        query = SQL::SelectStatement.new(nil, [SQL::SelectClause.new(SQL::DistinctMode::None,
          [SQL::AllColumns.new(nil)] of SQL::ResultColumn,
          SQL::From.new([SQL::FromItem.new(nil, SQL::TableReference.new(expression.schema, expression.table, nil, nil, false), nil, nil)]),
          nil, [] of SQL::Expression, nil, [] of SQL::WindowDefinition)] of SQL::SelectCore,
          [] of SQL::CompoundOperator, [] of SQL::OrderingTerm, nil)
        compile_in_select(expression.operand, query, expression.negated, context)
      when SQL::Exists
        plan = compile_subquery(expression.query, context)
        ExistsExpr.new(plan.producer, plan.outer_slots)
      when SQL::ScalarSubquery
        plan = compile_subquery(expression.query, context)
        width = plan.list_of_column_names.size
        if width > 1
          # A row value: each column read from the first row.
          row = RowSubqueryExpr.new(plan.producer, plan.outer_slots, width)
          columns = (0...width).map do |index|
            SubqueryColumnExpr.new(row, index, plan.list_of_affinities[index],
              plan.list_of_first_core_columns[index]?.try(&.collation_sequence)).as(Expr)
          end
          SubqueryVectorExpr.new(columns)
        else
          ScalarSubqueryExpr.new(plan.producer, plan.outer_slots, plan.list_of_affinities[0])
        end
      when SQL::CaseExpression then compile_case(expression, context)
      when SQL::Cast
        type_text = expression.type_name.try { |type_name| type_name_text(type_name) } || ""
        target = ValueSemantics::CastTarget.for_type(type_text)
        CastExpr.new(compile_expression(expression.operand, context), target,
          ExpressionAffinity.from(Affinity.from_declared_type(type_text)))
      when SQL::Collate
        collated = compile_expression(expression.operand, context)
        raise SQLError.new("row value misused") if collated.is_a?(VectorExpr)
        name = expression.collation.value
        CollateExpr.new(collated, collation_named(name), unknown_collation_name(name))
      when SQL::FunctionCall then compile_function(expression, context)
      when SQL::RowValue
        VectorExpr.new(expression.elements.map { |element| compile_expression(element, context) })
      when SQL::Raise
        # sqlite3ExprCodeTarget reports RAISE() outside a trigger when it
        # generates code, after every name has resolved.
        record_codegen_error("RAISE() may only be used within a trigger-program")
        ConstantExpr.new(nil)
      else
        raise UnsupportedSQL.new("expression #{expression.class.name}")
      end
    end

    private def type_name_text(type_name : SQL::TypeName) : String
      words = type_name.words.map(&.value).join(' ')
      return words if type_name.arguments.empty?
      "#{words}(#{type_name.arguments.join(',')})"
    end

    # ---------------------------------------------------------- literals

    private def compile_literal(literal : SQL::Literal, negative : Bool) : Expr
      value = case literal.kind
              in .null?    then nil
              in .integer? then literal_integer(literal.text, negative)
              in .float?
                real = NumericText.ato_f(literal.text.delete('_')).value
                negative ? -real : real
              in .string? then SQL::Parser.dequote(literal.text)
              in .blob?   then literal_blob(literal.text)
              in .current_time?, .current_date?, .current_timestamp?
                return DateTimeFunctions.keyword_expression(literal.kind)
              end
      ConstantExpr.new(value)
    end

    # An integer literal: decimal digits past the Int64 range read as a
    # REAL (codeInteger); hexadecimal is a 64-bit two's complement pattern.
    def literal_integer(text : String, negative : Bool) : Value
      digits = text.delete('_')
      if digits.size > 2 && digits[0] == '0' && digits[1].in?('x', 'X')
        hex = digits[2..]
        raise SQLError.new("hex literal too big: #{negative ? "-" : ""}#{text}") if hex.size > 16
        value = hex.to_u64(16).to_i64!
        return negative ? 0_i64 &- value : value
      end
      parse = NumericText.atoi64(negative ? "-#{digits}" : digits)
      if parse.code == 0 || (parse.code == 3 && negative)
        return parse.value
      end
      real = NumericText.ato_f(digits).value
      negative ? -real : real
    end

    private def literal_blob(text : String) : Bytes
      hex = text[2, text.size - 3]
      Bytes.new(hex.size // 2) { |index| hex[index * 2, 2].to_u8(16) }
    end

    # ---------------------------------------------------------- names

    private def resolve_column(reference : SQL::ColumnReference, context : QueryContext) : Expr
      column_name = reference.column.value
      table_name = reference.table.try(&.value)
      schema_name = reference.schema.try(&.value)
      if schema_name
        unless @session.schema?(schema_name)
          raise SQLError.new("no such column: #{schema_name}.#{table_name}.#{column_name}")
        end
        # lookupName: a schema-qualified name matches only FROM entries of
        # that schema's tables.
        schema_database = @session.existing_database_named(schema_name)
        return unresolved_column(schema_name, table_name, column_name) unless schema_database
      end
      current = context
      while current
        if found = resolve_in(current, column_name, table_name, schema_database)
          mark_correlated(context, current, found)
          return found
        end
        if table_name.nil? && current.aliases_visible?
          # lookupName checks each enclosing query's result aliases too
          # (NC_UEList), and resolveAlias copies the aliased expression in.
          if alias_entry = current.list_of_aliases.find { |entry| entry[0].compare(column_name, case_insensitive: true) == 0 }
            if (!current.aggregates_allowed? || current.inside_aggregate_call?) && contains_aggregate?(alias_entry[1])
              raise SQLError.new("misuse of aliased aggregate #{alias_entry[0]}")
            end
            saved = current.aliases_visible?
            current.aliases_visible = false
            begin
              compiled = compile_expression(alias_entry[1], current)
            ensure
              current.aliases_visible = saved
            end
            correlate_to_query(context, current) unless current.same?(context)
            return compiled
          end
        end
        current = current.parent
      end
      if table_name.nil? && reference.column.text.starts_with?('"')
        # SQLite's double-quoted string literal fallback (DQS).
        return ConstantExpr.new(column_name)
      end
      if table_name.nil?
        # sqlite3ExprIdToTrueFalse: an unresolved TRUE or FALSE is 1 or 0.
        return TrueFalseExpr.new(true) if column_name.compare("true", case_insensitive: true) == 0
        return TrueFalseExpr.new(false) if column_name.compare("false", case_insensitive: true) == 0
      end
      unresolved_column(schema_name, table_name, column_name)
    end

    private def unresolved_column(schema_name : String?, table_name : String?, column_name : String) : NoReturn
      full = if schema_name
               "#{schema_name}.#{table_name}.#{column_name}"
             elsif table_name
               "#{table_name}.#{column_name}"
             else
               column_name
             end
      raise SQLError.new("no such column: #{full}")
    end

    private def mark_correlated(context : QueryContext, owner : QueryContext, found : Expr) : Nil
      return if context.same?(owner)
      slot = found.as?(ColumnExpr).try(&.slot) || found.as?(RowidExpr).try(&.slot)
      return unless slot
      current = context
      while current && !current.same?(owner)
        current.correlated = true
        current.outer_slots << slot
        current = current.parent
      end
    end

    # The queries from *context* out to *owner* (not included) read a value
    # *owner* computes per row or group, so they run again for each.
    private def correlate_to_query(context : QueryContext, owner : QueryContext) : Nil
      slots = owner.list_of_entries.map(&.slot)
      current = context
      while current && !current.same?(owner)
        current.correlated = true
        slots.each { |slot| current.outer_slots << slot }
        current = current.parent
      end
    end

    # lookupName within one query level.
    private def resolve_in(context : QueryContext, column_name : String, table_name : String?,
                           schema_database : Database? = nil) : Expr?
      matches = [] of Expr
      candidates = context.list_of_entries.select do |entry|
        next false if schema_database && !schema_database.same?(entry.database)
        table_name.nil? || entry.match_name.compare(table_name, case_insensitive: true) == 0
      end
      candidates.each do |entry|
        if index = entry.column_index(column_name)
          next if table_name.nil? && entry.merged_columns.includes?(index)
          table = entry.table
          if table && table.rowid_alias == index
            matches << rowid_expression(entry)
          else
            matches << column_expression(entry, index)
          end
        end
      end
      if matches.size > 1
        raise SQLError.new("ambiguous column name: #{table_name ? "#{table_name}.#{column_name}" : column_name}")
      end
      return matches.first if matches.size == 1
      if ROWID_NAMES.includes?(column_name.downcase)
        with_rowid = candidates.select(&.has_rowid?)
        if with_rowid.size > 1
          raise SQLError.new("ambiguous column name: #{column_name}")
        end
        if entry = with_rowid.first?
          return rowid_expression(entry)
        end
      end
      nil
    end

    # ---------------------------------------------------------- operators

    private def compile_unary(expression : SQL::UnaryOperation, context : QueryContext) : Expr
      operand = expression.operand
      case expression.operator
      in .negate?
        if operand.is_a?(SQL::Literal) && (operand.kind.integer? || operand.kind.float?)
          return compile_literal(operand, negative: true)
        end
        NegateExpr.new(compile_expression(operand, context))
      in .plus?    then UnaryPlusExpr.new(compile_expression(operand, context))
      in .not?     then NotExpr.new(compile_expression(operand, context))
      in .bit_not? then BitNotExpr.new(compile_expression(operand, context))
      end
    end

    # parse.y binaryToUnaryIfNull: `x IS NULL`, `x IS NOT NULL` and the
    # DISTINCT FROM forms with a NULL literal are TK_ISNULL / TK_NOTNULL.
    private def null_comparison?(expression : SQL::Expression) : Bool
      return false unless expression.is_a?(SQL::BinaryOperation)
      operator = expression.operator
      return false unless operator.is? || operator.is_not? || operator.is_distinct_from? || operator.is_not_distinct_from?
      right = expression.right
      right.is_a?(SQL::Literal) && right.kind.null?
    end

    private def compile_binary(expression : SQL::BinaryOperation, context : QueryContext) : Expr
      operator = expression.operator
      if operator.extract? || operator.extract_text?
        # The parser makes `a -> b` the function "->" of two arguments.
        definition = ScalarFunctions.lookup(operator.extract? ? "->" : "->>", 2) || raise Error.new("JSON operator missing")
        return FunctionExpr.new(definition, [compile_expression(expression.left, context), compile_expression(expression.right, context)] of Expr)
      end
      null_test = null_comparison?(expression)
      left = null_test ? compile_null_test_operand(expression.left, context) : compile_expression(expression.left, context)
      right_syntax = expression.right
      right = null_test && right_syntax.is_a?(SQL::Literal) ? compile_literal(right_syntax, negative: false) : compile_expression(right_syntax, context)
      case operator
      when .or?          then LogicalExpr.new(false, left, right)
      when .and?         then LogicalExpr.new(true, left, right)
      when .add?         then ArithmeticExpr.new(ValueSemantics::Arithmetic::Add, left, right)
      when .subtract?    then ArithmeticExpr.new(ValueSemantics::Arithmetic::Subtract, left, right)
      when .multiply?    then ArithmeticExpr.new(ValueSemantics::Arithmetic::Multiply, left, right)
      when .divide?      then ArithmeticExpr.new(ValueSemantics::Arithmetic::Divide, left, right)
      when .remainder?   then ArithmeticExpr.new(ValueSemantics::Arithmetic::Remainder, left, right)
      when .concat?      then ConcatExpr.new(left, right)
      when .bit_and?     then BitwiseExpr.new(ValueSemantics::Bitwise::And, left, right)
      when .bit_or?      then BitwiseExpr.new(ValueSemantics::Bitwise::Or, left, right)
      when .shift_left?  then BitwiseExpr.new(ValueSemantics::Bitwise::ShiftLeft, left, right)
      when .shift_right? then BitwiseExpr.new(ValueSemantics::Bitwise::ShiftRight, left, right)
      else
        comparison = case operator
                     when .equal?, .double_equal?      then ComparisonOperator::Equal
                     when .not_equal?, .less_greater?  then ComparisonOperator::NotEqual
                     when .less?                       then ComparisonOperator::Less
                     when .less_or_equal?              then ComparisonOperator::LessOrEqual
                     when .greater?                    then ComparisonOperator::Greater
                     when .greater_or_equal?           then ComparisonOperator::GreaterOrEqual
                     when .is?, .is_not_distinct_from? then ComparisonOperator::Is
                     else                                   ComparisonOperator::IsNot
                     end
        compile_comparison(comparison, left, right)
      end
    end

    # The unknown collation sqlite3BinaryCompareCollSeq looks up for a
    # comparison of *left* with *right*: the left operand's COLLATE, else
    # the right one's.
    private def compared_unknown_collation(left : Expr, right : Expr) : String?
      return left.unknown_collation if left.explicit_collate?
      right.unknown_collation if right.explicit_collate?
    end

    private def compile_comparison(operator : ComparisonOperator, left : Expr, right : Expr) : Expr
      # resolveExprStep: IS and IS NOT against TRUE or FALSE are truth tests.
      truth = right
      while truth.is_a?(CollateExpr) || truth.is_a?(PassThroughExpr)
        truth = truth.children.first
      end
      if (operator.is? || operator.is_not?) && truth.is_a?(TrueFalseExpr) && !left.is_a?(VectorExpr)
        return TruthExpr.new(left, truth.true?, operator.is_not?)
      end
      left_vector = left.as?(VectorExpr)
      right_vector = right.as?(VectorExpr)
      if left_vector || right_vector
        left_elements = left_vector.try(&.elements) || [left]
        right_elements = right_vector.try(&.elements) || [right]
        unless left_elements.size == right_elements.size
          raise SQLError.new("row value misused")
        end
        # Nested row values compare element by element, so a matching
        # nesting flattens: (2, (2, 0)) IS (2, (2, 0)).
        flat_left = [] of Expr
        flat_right = [] of Expr
        left_elements.each_with_index do |element, index|
          other = right_elements[index]
          if element.is_a?(VectorExpr) || other.is_a?(VectorExpr)
            inner_left = element.as?(VectorExpr).try(&.elements) || [element]
            inner_right = other.as?(VectorExpr).try(&.elements) || [other]
            raise SQLError.new("row value misused") unless inner_left.size == inner_right.size && inner_left.size > 1
            flat_left.concat(inner_left)
            flat_right.concat(inner_right)
          else
            flat_left << element
            flat_right << other
          end
        end
        if (flat_left + flat_right).any?(VectorExpr)
          raise UnsupportedSQL.new("row values nested more than one level")
        end
        flat_left.each_with_index { |element, index| note_collation_use(compared_unknown_collation(element, flat_right[index])) }
        return VectorComparisonExpr.new(operator, flat_left, flat_right)
      end
      note_collation_use(compared_unknown_collation(left, right))
      ComparisonExpr.new(operator, left, right)
    end

    private def compile_like(expression : SQL::LikeOperation, context : QueryContext) : Expr
      compile_like_call(expression, context)
    rescue ResolveAbort
      # C ignores the walk result of a function's argument list.
      ConstantExpr.new(nil)
    rescue error : SQLError
      errors = @list_of_name_errors
      raise error if errors.nil? || error.is_a?(ResolveError) || !ExpressionCompiler.continuing_error?(error)
      errors << error
      begin
        compile_expression(expression.pattern, context)
        compile_expression(expression.operand, context)
      rescue ResolveAbort
      end
      ConstantExpr.new(nil)
    end

    private def compile_like_call(expression : SQL::LikeOperation, context : QueryContext) : Expr
      # parse.y builds like(pattern, operand[, escape]): the function is
      # checked first, then the pattern is walked before the operand.
      regexp = nil
      if expression.operator == "REGEXP"
        regexp = @session.user_function("regexp", 2) || raise SQLError.new("no such function: REGEXP")
      end
      pattern = compile_expression(expression.pattern, context)
      operand = compile_expression(expression.operand, context)
      escape = expression.escape.try { |escape_expression| compile_expression(escape_expression, context) }
      case expression.operator
      when "LIKE" then LikeExpr.new(operand, pattern, escape, glob: false, negated: expression.negated)
      when "GLOB" then LikeExpr.new(operand, pattern, escape, glob: true, negated: expression.negated)
      when "REGEXP"
        function = regexp || raise SQLError.new("no such function: REGEXP")
        call = UserFunctionExpr.new("regexp", function, [pattern, operand] of Expr)
        expression.negated ? NotExpr.new(call) : call
      else
        raise UnsupportedSQL.new("#{expression.operator} operator")
      end
    end

    private def compile_in_list(expression : SQL::InList, context : QueryContext) : Expr
      # The parser replaces `x IN ()` with FALSE (`NOT IN ()` with TRUE) and
      # drops x unresolved.
      return TrueFalseExpr.new(expression.negated) if expression.values.empty?
      # parse.y: `x IN ((SELECT ...))`, one list element that is a
      # subquery, is an IN-subquery like `x IN (SELECT ...)`.
      if expression.values.size == 1 && (subquery = expression.values[0]).is_a?(SQL::ScalarSubquery)
        return compile_in_select(expression.operand, subquery.query, expression.negated, context)
      end
      # sqlite3ExprListToValues (at parse time): with a row value on the
      # left, every list element must have as many terms.
      if (row = expression.operand).is_a?(SQL::RowValue) && row.elements.size > 1
        expected = row.elements.size
        expression.values.each do |value|
          terms = value.is_a?(SQL::RowValue) ? value.elements.size : 1
          next if terms == expected
          raise SQLError.new("IN(...) element has #{terms} term#{terms > 1 ? "s" : ""} - expected #{expected}")
        end
      end
      operand = compile_expression(expression.operand, context)
      values = expression.values.map { |value| compile_expression(value, context) }
      if vector = operand.as?(VectorExpr)
        alternatives = values.map do |value|
          elements = value.as?(VectorExpr).try(&.elements) || raise SQLError.new("row value misused")
          raise SQLError.new("row value misused") unless elements.size == vector.elements.size
          VectorComparisonExpr.new(ComparisonOperator::Equal, vector.elements, elements).as(Expr)
        end
        either = alternatives.reduce { |all, alternative| LogicalExpr.new(false, all, alternative).as(Expr) }
        return expression.negated ? NotExpr.new(either) : either
      end
      if values.any?(VectorExpr)
        raise SQLError.new("row value misused")
      end
      note_collation_use(operand.unknown_collation) if operand.explicit_collate?
      InListExpr.new(operand, values, expression.negated)
    end

    private def compile_in_select(operand_syntax : SQL::Expression, query : SQL::SelectStatement, negated : Bool,
                                  context : QueryContext) : Expr
      # resolveExprStep resolves the subquery of an IN when it meets the IN,
      # before walking down to the left operand.
      plan = compile_subquery(query, context)
      operand = compile_expression(operand_syntax, context)
      operands = operand.as?(VectorExpr).try(&.elements) || [operand]
      width = plan.list_of_column_names.size
      unless width == operands.size
        raise SQLError.new("sub-select returns #{width} columns - expected #{operands.size}")
      end
      affinities = operands.map_with_index do |left, index|
        ValueSemantics.comparison_affinity(plan.list_of_affinities[index], left.affinity)
      end
      operands.each_with_index do |left, index|
        if left.explicit_collate?
          note_collation_use(left.unknown_collation)
        elsif (column = plan.list_of_first_core_columns[index]?) && column.explicit_collate?
          note_collation_use(column.unknown_collation)
        end
      end
      collations = operands.map_with_index do |left, index|
        Query.binary_collation(left, plan.list_of_first_core_columns[index]?)
      end
      descending = operands.size == 1 && descending_index_for_in?(query, plan, operands[0], context)
      InSelectExpr.new(plan.producer, plan.outer_slots, operands, affinities, collations, negated,
        nulls_from_first_entry_only: descending)
    end

    # sqlite3FindInIndex: `x IN (SELECT col FROM table)` (one table, no
    # WHERE, DISTINCT, aggregate or LIMIT) reads an existing index on col
    # when the comparison's affinity and collation allow, the newest such
    # index first. Whether the set holds a NULL is then taken from the
    # index's first entry (sqlite3SetHasNullFlag); on an index whose column
    # is DESC that entry is the largest value, so a NULL counts only when
    # every value is NULL. True when SQLite would read such an index.
    private def descending_index_for_in?(query : SQL::SelectStatement, plan : QueryPlan, left : Expr,
                                         context : QueryContext) : Bool
      return false unless query.with_clause.nil? && query.cores.size == 1 && query.limit.nil? && plan.outer_slots.empty?
      core = query.cores[0]
      return false unless core.is_a?(SQL::SelectClause)
      return false if core.distinct.distinct? || core.where || !core.group_by.empty? || core.having
      return false if core.columns.any? { |column| !column.is_a?(SQL::ExpressionColumn) || contains_aggregate?(column.expression) }
      from = core.from
      return false unless from && from.items.size == 1
      source = from.items[0].source
      return false unless source.is_a?(SQL::TableReference)
      return false if context.ctes.try(&.find(source.name.value))
      table = @session.table(source.name.value)
      return false unless table
      column = plan.list_of_first_core_columns[0]?
      return false unless column.is_a?(ColumnExpr)
      position = column.column
      return false if table.definition.list_of_columns[position]?.try(&.not_null?)
      index_affinity = table.list_of_affinities[position]
      comparison = ValueSemantics.comparison_affinity(left.affinity, index_affinity)
      return false if comparison >= ExpressionAffinity::Numeric && !index_affinity.numeric?
      required = Query.binary_collation(left, column)
      table.list_of_indexes.reverse_each do |layout|
        next if layout.needs_evaluation?
        next unless layout.list_of_key_positions.first? == position
        key = layout.comparator.list_of_key_columns.first?
        next unless key && key.collation == required
        return key.descending
      end
      false
    end

    # Compiles a subquery inside an expression of *context*. Returns the
    # plan and whether it refers to rows outside itself.
    # resolveExprStep walks an IS NULL or NOT NULL operand on its own and
    # goes on whatever the walk returned: a name error there is kept as the
    # message and the walk continues past it.
    private def compile_null_test_operand(operand : SQL::Expression, context : QueryContext) : Expr
      compile_expression(operand, context)
    rescue ResolveAbort
      ConstantExpr.new(nil)
    rescue error : SQLError
      errors = @list_of_name_errors
      raise error unless errors && (error.is_a?(ResolveError) || ExpressionCompiler.lookup_error?(error))
      errors << error
      ConstantExpr.new(nil)
    end

    private def compile_subquery(query : SQL::SelectStatement, context : QueryContext) : QueryPlan
      # A subquery met after an error is recorded is not resolved: the
      # recorded message stands (resolveSelectStep stops on pParse->nErr).
      if (errors = @list_of_name_errors) && (last = errors.last?)
        raise ResolveError.new(last.message || "SQL error", last.result_code)
      end
      saved_aggregates = context.aggregates
      plan = compile_query(query, context, context.ctes)
      context.aggregates = saved_aggregates
      plan.outer_slots.each do |slot|
        next if context.owns_slot?(slot)
        context.correlated = true
        context.outer_slots << slot
      end
      plan
    end

    private def compile_case(expression : SQL::CaseExpression, context : QueryContext) : Expr
      # The walk goes operand, then each WHEN and its THEN, then ELSE.
      operand = expression.operand.try { |syntax| compile_expression(syntax, context) }
      conditions = [] of Expr
      results = [] of Expr
      expression.branches.each do |branch|
        conditions << compile_expression(branch.condition, context)
        results << compile_expression(branch.result, context)
      end
      else_result = expression.else_result.try { |syntax| compile_expression(syntax, context) }
      if operand.is_a?(VectorExpr)
        # sqlite3ExprCodeTarget's TK_CASE tests `operand = WHEN` for each
        # branch, so a row value operand compares with row value WHENs.
        conditions = conditions.map { |condition| compile_comparison(ComparisonOperator::Equal, operand, condition).as(Expr) }
        return CaseExpr.new(nil, conditions, results, else_result)
      end
      CaseExpr.new(operand, conditions, results, else_result)
    end

    # ---------------------------------------------------------- functions

    # Whether *name* is shaped like a json.c function: `json` or `jsonb`,
    # optionally followed by `_` and lower-case letters or underscores
    # (`/\Ajsonb?(_[a-z_]+)?\z/`). A function so named that the engine does
    # not have is reported as unsupported.
    def self.json_function_name?(name : String) : Bool
      rest = name.lchop?("jsonb") || name.lchop?("json")
      return false unless rest
      return true if rest.empty?
      rest.size > 1 && rest.starts_with?('_') && rest.each_byte.all? { |byte| byte.unsafe_chr.ascii_lowercase? || byte === '_' }
    end

    # resolveExprStep checks a function before walking its arguments: its
    # own error is recorded first, and the arguments are walked after it.
    private def compile_function(call : SQL::FunctionCall, context : QueryContext) : Expr
      compile_function_call(call, context)
    rescue ResolveAbort
      # An argument's walk stopped; C ignores the argument list's result.
      ConstantExpr.new(nil)
    rescue error : SQLError
      errors = @list_of_name_errors
      raise error if errors.nil? || error.is_a?(ResolveError) || !ExpressionCompiler.continuing_error?(error)
      errors << error
      begin
        call.arguments.each { |argument| compile_expression(argument, context) }
        call.filter.try { |filter| compile_expression(filter, context) }
      rescue ResolveAbort
      end
      ConstantExpr.new(nil)
    end

    private def compile_function_call(call : SQL::FunctionCall, context : QueryContext) : Expr
      name = call.name.value
      lower = name.downcase
      if call.over || call.over_name
        raise UnsupportedSQL.new("window function #{name}()")
      end
      count = call.arguments.size
      if kind = AggregateFunctions.kind_for(name, count, call.star)
        return compile_aggregate(call, kind, context)
      end
      if call.star
        known = ScalarFunctions.known?(lower) || @session.user_function(lower, -1) || @session.user_function(lower, 0)
        raise SQLError.new("no such function: #{name}") unless known
        # parse.y: `name(*)` calls a function with no arguments, so
        # sqlite_version(*) and random(*) work (Rails asks for
        # sqlite_version(*)).
        takes_no_arguments = @session.user_function(lower, 0) || ScalarFunctions.accepts?(lower, 0)
        raise SQLError.new("wrong number of arguments to function #{name}()") unless takes_no_arguments
      end
      if call.distinct.distinct?
        raise SQLError.new("DISTINCT aggregates must have exactly one argument") if ScalarFunctions.known?(lower)
      end
      if ExpressionCompiler.json_function_name?(lower) && !ScalarFunctions.known?(lower)
        raise UnsupportedSQL.new("JSON function #{name}() (milestone G6)")
      end
      unless call.order_by.empty?
        raise SQLError.new("ORDER BY may not be used with non-aggregate #{name}()")
      end
      raise SQLError.new("FILTER may not be used with non-aggregate #{name}()") if call.filter
      if user = @session.user_function(lower, count)
        arguments = call.arguments.map { |argument| compile_expression(argument, context) }
        return UserFunctionExpr.new(lower, user, arguments)
      end
      case lower
      when "coalesce", "ifnull"
        if (lower == "ifnull" && count != 2) || count < 2
          raise SQLError.new("wrong number of arguments to function #{name}()")
        end
        return CoalesceExpr.new(call.arguments.map { |argument| compile_expression(argument, context) })
      when "iif", "if"
        raise SQLError.new("wrong number of arguments to function #{name}()") if count < 2
        return IifExpr.new(call.arguments.map { |argument| compile_expression(argument, context) })
      when "subtype"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 1
        return SubtypeExpr.new(compile_expression(call.arguments[0], context))
      when "likely", "unlikely"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 1
        return PassThroughExpr.new(compile_expression(call.arguments[0], context))
      when "likelihood"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 2
        # exprProbability: the probability is a floating-point literal no
        # greater than 1.0.
        probability = call.arguments[1]
        unless probability.is_a?(SQL::Literal) && probability.kind.float? && NumericText.ato_f(probability.text.to_slice).value <= 1.0
          raise SQLError.new("second argument to likelihood() must be a constant between 0.0 and 1.0")
        end
        return PassThroughExpr.new(compile_expression(call.arguments[0], context))
      when "printf", "format"
        raise UnsupportedSQL.new("function #{name}()")
      end
      if !ScalarFunctions.known?(lower) && ExpressionCompiler.json_function_name?(lower)
        raise UnsupportedSQL.new("JSON function #{name}() (milestone G6)")
      end
      definition = ScalarFunctions.lookup(lower, count) || raise SQLError.new("no such function: #{name}")
      arguments = call.arguments.map { |argument| compile_expression(argument, context) }
      function = definition.reads_subtypes ? SubtypeReadingFunctionExpr.new(definition, arguments) : FunctionExpr.new(definition, arguments)
      note_collation_use(function.needed_unknown_collation)
      function
    end

    private def compile_aggregate(call : SQL::FunctionCall, kind : AggregateFunctions::Kind, context : QueryContext) : Expr
      name = call.name.value
      if !context.aggregates_allowed? || context.inside_aggregate_call?
        raise SQLError.new("misuse of aggregate function #{name}()")
      end
      if call.distinct.distinct? && call.arguments.size != 1
        raise SQLError.new("DISTINCT aggregates must have exactly one argument")
      end
      raise UnsupportedSQL.new("ORDER BY inside aggregate #{name}()") unless call.order_by.empty?
      context.inside_aggregate_call = true
      saved_aliases = context.aliases_visible?
      begin
        arguments = call.arguments.map { |argument| compile_expression(argument, context) }
        filter = call.filter.try { |expression| compile_expression(expression, context) }
      ensure
        context.aliases_visible = saved_aliases
        context.inside_aggregate_call = false
      end
      collation = arguments.compact_map(&.collation_sequence).first? || Collation::Binary
      # min() and max() compare with the collation, and a DISTINCT
      # aggregate keys its set with it.
      if kind.min? || kind.max? || call.distinct.distinct?
        note_collation_use(arguments.find(&.explicit_collate?).try(&.unknown_collation))
      end
      index = allocate_aggregate
      # resolveExprStep: the aggregate belongs to the innermost query whose
      # FROM its arguments read (sqlite3ReferencesSrcList); with no column
      # at all, to the query it is written in.
      owner = aggregate_owner(arguments, filter, context)
      collector = owner.aggregates
      if collector.nil? || owner.inside_aggregate_call?
        # analyzeAggregate never collects it: SQLite fails while generating
        # code for it.
        record_codegen_error("misuse of aggregate: #{name}()")
      else
        collector.list_of_calls << AggregateCall.new(kind, arguments, call.distinct.distinct?, filter, collation, index)
      end
      kind.json? ? JsonAggregateResultExpr.new(index) : AggregateResultExpr.new(index)
    end

    private def aggregate_owner(arguments : Array(Expr), filter : Expr?, context : QueryContext) : QueryContext
      used = Set(Int32).new
      arguments.each { |argument| ExpressionWalk.slots(argument, used) }
      ExpressionWalk.slots(filter, used) if filter
      return context if used.empty?
      current = context
      while current
        return current if current.list_of_entries.any? { |entry| used.includes?(entry.slot) }
        current = current.parent
      end
      context
    end
  end
end
