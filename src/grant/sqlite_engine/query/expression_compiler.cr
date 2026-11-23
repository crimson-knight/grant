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

    # A name error the resolver records and walks on past (lookupName turns
    # the name into NULL and counts nNcErr): within one expression the first
    # such error, in walk order, is the one reported; a function's own error
    # comes after its arguments'.
    CONTINUING_ERROR = /\A(no such column|ambiguous column name|no such function|wrong number of arguments|misuse of aggregate)/

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
      if first = errors.first?
        raise ResolveError.new(first.message || "SQL error", first.result_code)
      end
      compiled
    end

    # Records *error* when an expression is being resolved; false otherwise.
    private def record_name_error(error : SQLError) : Bool
      errors = @list_of_name_errors
      return false if errors.nil? || error.is_a?(ResolveError) || !CONTINUING_ERROR.matches?(error.message || "")
      errors << error
      true
    end

    def compile_expression(expression : SQL::Expression, context : QueryContext) : Expr
      compile_expression_node(expression, context)
    rescue error : SQLError
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
        NullTestExpr.new(compile_expression(expression.operand, context), negated: !expression.form.is_null_keyword?)
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
        CollateExpr.new(collated, collation_named(expression.collation.value))
      when SQL::FunctionCall then compile_function(expression, context)
      when SQL::RowValue
        VectorExpr.new(expression.elements.map { |element| compile_expression(element, context) })
      when SQL::Raise
        raise SQLError.new("RAISE() may only be used within a trigger-program")
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
                now = Time.utc
                case literal.kind
                when .current_time? then now.to_s("%H:%M:%S")
                when .current_date? then now.to_s("%Y-%m-%d")
                else                     now.to_s("%Y-%m-%d %H:%M:%S")
                end
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
      if schema = reference.schema
        unless schema.value.compare("main", case_insensitive: true) == 0
          raise SQLError.new("no such column: #{schema.value}.#{table_name}.#{column_name}")
        end
      end
      current = context
      while current
        if found = resolve_in(current, column_name, table_name)
          mark_correlated(context, current, found)
          return found
        end
        if table_name.nil? && current.aliases_visible?
          if alias_entry = current.list_of_aliases.find { |entry| entry[0].compare(column_name, case_insensitive: true) == 0 }
            if current.same?(context)
              if current.aggregates.nil? && !current.aggregate_query? && contains_aggregate?(alias_entry[1])
                raise SQLError.new("misuse of aliased aggregate #{alias_entry[0]}")
              end
              saved = current.aliases_visible?
              current.aliases_visible = false
              compiled = compile_expression(alias_entry[1], current)
              current.aliases_visible = saved
              return compiled
            end
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
      full = table_name ? "#{table_name}.#{column_name}" : column_name
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

    # lookupName within one query level.
    private def resolve_in(context : QueryContext, column_name : String, table_name : String?) : Expr?
      matches = [] of Expr
      candidates = context.list_of_entries.select do |entry|
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

    private def compile_binary(expression : SQL::BinaryOperation, context : QueryContext) : Expr
      operator = expression.operator
      if operator.extract? || operator.extract_text?
        raise UnsupportedSQL.new("the -> and ->> operators (JSON)")
      end
      left = compile_expression(expression.left, context)
      right = compile_expression(expression.right, context)
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
        return VectorComparisonExpr.new(operator, flat_left, flat_right)
      end
      ComparisonExpr.new(operator, left, right)
    end

    private def compile_like(expression : SQL::LikeOperation, context : QueryContext) : Expr
      operand = compile_expression(expression.operand, context)
      pattern = compile_expression(expression.pattern, context)
      escape = expression.escape.try { |escape_expression| compile_expression(escape_expression, context) }
      case expression.operator
      when "LIKE" then LikeExpr.new(operand, pattern, escape, glob: false, negated: expression.negated)
      when "GLOB" then LikeExpr.new(operand, pattern, escape, glob: true, negated: expression.negated)
      when "REGEXP"
        function = @session.user_function("regexp", 2) || raise SQLError.new("no such function: REGEXP")
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
      InListExpr.new(operand, values, expression.negated)
    end

    private def compile_in_select(operand_syntax : SQL::Expression, query : SQL::SelectStatement, negated : Bool,
                                  context : QueryContext) : Expr
      operand = compile_expression(operand_syntax, context)
      operands = operand.as?(VectorExpr).try(&.elements) || [operand]
      plan = compile_subquery(query, context)
      width = plan.list_of_column_names.size
      unless width == operands.size
        raise SQLError.new("sub-select returns #{width} columns - expected #{operands.size}")
      end
      affinities = operands.map_with_index do |left, index|
        ValueSemantics.comparison_affinity(plan.list_of_affinities[index], left.affinity)
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
        next if layout.unsupported_reason
        next unless layout.list_of_key_positions.first? == position
        key = layout.comparator.list_of_key_columns.first?
        next unless key && key.collation == required
        return key.descending
      end
      false
    end

    # Compiles a subquery inside an expression of *context*. Returns the
    # plan and whether it refers to rows outside itself.
    private def compile_subquery(query : SQL::SelectStatement, context : QueryContext) : QueryPlan
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
      operand = expression.operand.try { |syntax| compile_expression(syntax, context) }
      conditions = expression.branches.map { |branch| compile_expression(branch.condition, context) }
      results = expression.branches.map { |branch| compile_expression(branch.result, context) }
      else_result = expression.else_result.try { |syntax| compile_expression(syntax, context) }
      CaseExpr.new(operand, conditions, results, else_result)
    end

    # ---------------------------------------------------------- functions

    # The JSON functions of json.c, which arrive with milestone G6.
    JSON_FUNCTION_NAME = /\Ajsonb?(_[a-z_]+)?\z/

    private def compile_function(call : SQL::FunctionCall, context : QueryContext) : Expr
      name = call.name.value
      lower = name.downcase
      if call.over || call.over_name
        raise UnsupportedSQL.new("window function #{name}()")
      end
      count = call.arguments.size
      if kind = AggregateFunctions.kind_for(lower, count, call.star)
        return compile_aggregate(call, kind, context)
      end
      if call.star
        known = ScalarFunctions.known?(lower) || @session.user_function(lower, -1) || @session.user_function(lower, 0)
        raise SQLError.new("no such function: #{name}") unless known
        raise SQLError.new("wrong number of arguments to function #{name}()")
      end
      if call.distinct.distinct?
        raise SQLError.new("DISTINCT aggregates must have exactly one argument") if ScalarFunctions.known?(lower)
      end
      if JSON_FUNCTION_NAME.matches?(lower) && !ScalarFunctions.known?(lower)
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
      when "printf", "format", "json", "json_extract", "date", "time", "datetime", "julianday", "strftime", "unixepoch"
        raise UnsupportedSQL.new("function #{name}()")
      end
      if !ScalarFunctions.known?(lower) && JSON_FUNCTION_NAME.matches?(lower)
        raise UnsupportedSQL.new("JSON function #{name}() (milestone G6)")
      end
      # The arguments resolve before the function's own errors are reported.
      arguments = call.arguments.map { |argument| compile_expression(argument, context) }
      definition = begin
        ScalarFunctions.lookup(lower, count) || raise SQLError.new("no such function: #{name}")
      rescue error : SQLError
        raise error unless record_name_error(error)
        return ConstantExpr.new(nil)
      end
      FunctionExpr.new(definition, arguments)
    end

    private def compile_aggregate(call : SQL::FunctionCall, kind : AggregateFunctions::Kind, context : QueryContext) : Expr
      collector = context.aggregates
      name = call.name.value
      if collector.nil? || collector.inside_call?
        raise SQLError.new("misuse of aggregate function #{name}()")
      end
      if call.distinct.distinct? && call.arguments.size != 1
        raise SQLError.new("DISTINCT aggregates must have exactly one argument")
      end
      raise UnsupportedSQL.new("ORDER BY inside aggregate #{name}()") unless call.order_by.empty?
      collector.inside_call = true
      saved_aliases = context.aliases_visible?
      arguments = call.arguments.map { |argument| compile_expression(argument, context) }
      filter = call.filter.try { |expression| compile_expression(expression, context) }
      context.aliases_visible = saved_aliases
      collector.inside_call = false
      collation = arguments.compact_map(&.collation_sequence).first? || Collation::Binary
      index = allocate_aggregate
      collector.list_of_calls << AggregateCall.new(kind, arguments, call.distinct.distinct?, filter, collation, index)
      AggregateResultExpr.new(index)
    end
  end
end
