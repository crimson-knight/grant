module Grant::SQLiteEngine::SQL
  class Expression
    # SQLite's Expr.nHeight for this node (expr.c, exprSetHeight). Not part
    # of the node's value.
    property height : Int32 = 1
  end

  class SelectStatement
    # The tallest expression this SELECT holds (expr.c, heightOfSelect).
    property expression_height : Int32 = 0
  end

  # Expressions (lang_expr.html), parsed by precedence climbing with
  # parse.y's precedence table.
  module ExpressionParsing
    LEVEL_OR             =  1
    LEVEL_AND            =  2
    LEVEL_NOT            =  3
    LEVEL_EQUALITY       =  4 # IS MATCH LIKE BETWEEN IN ISNULL NOTNULL <> =
    LEVEL_COMPARISON     =  5 # < <= > >=
    LEVEL_BITWISE        =  7 # & | << >>
    LEVEL_ADDITIVE       =  8
    LEVEL_MULTIPLICATIVE =  9
    LEVEL_CONCAT         = 10 # || -> ->>
    LEVEL_COLLATE        = 11
    LEVEL_UNARY          = 12

    # Parses an expression whose operators all bind at least as tightly as
    # *min_level*. With *stop_at_and*, an AND at this level ends the
    # expression (the low bound of BETWEEN).
    private def parse_expression(min_level : Int32 = LEVEL_OR, stop_at_and : Bool = false) : Expression
      nested do
        left = parse_prefix
        loop do
          level = infix_level
          break if level.nil? || level < min_level
          break if stop_at_and && kind.and?
          left = parse_infix(left, level)
        end
        left
      end
    end

    private def infix_level : Int32?
      case kind
      when .or?  then LEVEL_OR
      when .and? then LEVEL_AND
      when .is?, .match?, .like_keyword?, .between?, .in?, .is_null?, .not_null?, .not_equal?, .equal?
        LEVEL_EQUALITY
      when .not?
        following = kind(1)
        if following.null? || following.like_keyword? || following.match? || following.between? || following.in?
          LEVEL_EQUALITY
        end
      when .less?, .less_or_equal?, .greater?, .greater_or_equal? then LEVEL_COMPARISON
      when .bit_and?, .bit_or?, .shift_left?, .shift_right?       then LEVEL_BITWISE
      when .plus?, .minus?                                        then LEVEL_ADDITIVE
      when .star?, .slash?, .remainder?                           then LEVEL_MULTIPLICATIVE
      when .concat?, .pointer?                                    then LEVEL_CONCAT
      when .collate?                                              then LEVEL_COLLATE
      end
    end

    private def parse_infix(left : Expression, level : Int32) : Expression
      token = peek
      case token.kind
      when .is?
        advance
        negated = accept(TokenKind::Not)
        distinct = accept(TokenKind::Distinct)
        expect(TokenKind::From) if distinct
        right = parse_expression(level + 1)
        operator = if distinct
                     negated ? BinaryOperator::IsNotDistinctFrom : BinaryOperator::IsDistinctFrom
                   else
                     negated ? BinaryOperator::IsNot : BinaryOperator::Is
                   end
        measured(BinaryOperation.new(operator, left, right), left.height, right.height)
      when .is_null?
        advance
        measured(NullTest.new(left, NullTestForm::IsNullKeyword), left.height)
      when .not_null?
        advance
        measured(NullTest.new(left, NullTestForm::NotNullKeyword), left.height)
      when .not?
        advance
        case kind
        when .null?
          advance
          measured(NullTest.new(left, NullTestForm::NotNullWords), left.height)
        when .between? then parse_between(left, negated: true)
        when .in?      then parse_in(left, negated: true)
        else                parse_like(left, negated: true)
        end
      when .like_keyword?, .match? then parse_like(left, negated: false)
      when .between?               then parse_between(left, negated: false)
      when .in?                    then parse_in(left, negated: false)
      when .collate?
        advance
        collation = parse_ids
        # sqlite3ExprAddCollateToken allocates a fresh node of height 1.
        Collate.new(left, collation)
      else
        advance
        right = parse_expression(level + 1)
        measured(BinaryOperation.new(binary_operator(token), left, right), left.height, right.height)
      end
    end

    private def binary_operator(token : Token) : BinaryOperator
      case token.kind
      when .or?               then BinaryOperator::Or
      when .and?              then BinaryOperator::And
      when .equal?            then token.size == 2 ? BinaryOperator::DoubleEqual : BinaryOperator::Equal
      when .not_equal?        then text(token) == "<>" ? BinaryOperator::LessGreater : BinaryOperator::NotEqual
      when .less?             then BinaryOperator::Less
      when .less_or_equal?    then BinaryOperator::LessOrEqual
      when .greater?          then BinaryOperator::Greater
      when .greater_or_equal? then BinaryOperator::GreaterOrEqual
      when .bit_and?          then BinaryOperator::BitAnd
      when .bit_or?           then BinaryOperator::BitOr
      when .shift_left?       then BinaryOperator::ShiftLeft
      when .shift_right?      then BinaryOperator::ShiftRight
      when .plus?             then BinaryOperator::Add
      when .minus?            then BinaryOperator::Subtract
      when .star?             then BinaryOperator::Multiply
      when .slash?            then BinaryOperator::Divide
      when .remainder?        then BinaryOperator::Remainder
      when .concat?           then BinaryOperator::Concat
      when .pointer?          then token.size == 3 ? BinaryOperator::ExtractText : BinaryOperator::Extract
      else                         syntax_error(token)
      end
    end

    private def parse_like(left : Expression, negated : Bool) : Expression
      syntax_error unless kind.like_keyword? || kind.match?
      operator = text(advance).upcase
      pattern = parse_expression(LEVEL_EQUALITY + 1)
      escape = accept(TokenKind::Escape) ? parse_expression(LEVEL_EQUALITY + 1) : nil
      height = Math.max(left.height, pattern.height)
      height = Math.max(height, escape.height) if escape
      height += 1 if negated
      measured(LikeOperation.new(operator, negated, left, pattern, escape), height)
    end

    private def parse_between(left : Expression, negated : Bool) : Expression
      expect(TokenKind::Between)
      low = parse_expression(LEVEL_OR, stop_at_and: true)
      expect(TokenKind::And)
      high = parse_expression(LEVEL_EQUALITY + 1)
      height = {left.height, low.height, high.height}.max
      height += 1 if negated
      measured(Between.new(left, negated, low, high), height)
    end

    private def parse_in(left : Expression, negated : Bool) : Expression
      expect(TokenKind::In)
      extra = negated ? 1 : 0
      if accept(TokenKind::LeftParen)
        if select_start?
          query = parse_select
          expect(TokenKind::RightParen)
          return measured(InSelect.new(left, negated, query), Math.max(left.height, query.expression_height) + extra)
        end
        values = kind.right_paren? ? [] of Expression : parse_expression_list
        expect(TokenKind::RightParen)
        height = values.max_of?(&.height) || 0
        return measured(InList.new(left, negated, values), Math.max(left.height, height) + extra)
      end
      schema, table = parse_qualified_name
      arguments = nil
      if accept(TokenKind::LeftParen)
        arguments = kind.right_paren? ? [] of Expression : parse_expression_list
        expect(TokenKind::RightParen)
      end
      measured(InTable.new(left, negated, schema, table, arguments), left.height + 1 + extra)
    end

    private def parse_prefix : Expression
      case kind
      when .not?
        advance
        operand = parse_expression(LEVEL_EQUALITY)
        measured(UnaryOperation.new(UnaryOperator::Not, operand), operand.height)
      when .minus?, .plus?
        operator = advance.kind.minus? ? UnaryOperator::Negate : UnaryOperator::Plus
        operand = parse_expression(LEVEL_UNARY)
        # parse.y folds a sign applied to a unary plus into that node.
        if operand.is_a?(UnaryOperation) && operand.operator.plus?
          node = UnaryOperation.new(operator, operand)
          node.height = operand.height
          node
        else
          measured(UnaryOperation.new(operator, operand), operand.height)
        end
      when .bit_not?
        advance
        operand = parse_expression(LEVEL_UNARY)
        measured(UnaryOperation.new(UnaryOperator::BitNot, operand), operand.height)
      else
        parse_primary
      end
    end

    private def parse_primary : Expression
      token = peek
      case token.kind
      when .left_paren?           then parse_parenthesized
      when .null?                 then advance; Literal.new(LiteralKind::Null, text(token))
      when .integer?              then advance; Literal.new(LiteralKind::Integer, text(token))
      when .float?                then advance; Literal.new(LiteralKind::Float, text(token))
      when .blob?                 then advance; Literal.new(LiteralKind::Blob, text(token))
      when .quoted_number?        then parse_quoted_number
      when .variable?             then parse_parameter
      when .current_time_keyword? then advance; current_time_literal(token)
      when .cast?                 then parse_cast
      when .case?                 then parse_case
      when .exists?
        advance
        expect(TokenKind::LeftParen)
        query = parse_select
        expect(TokenKind::RightParen)
        measured(Exists.new(query), query.expression_height)
      when .raise? then parse_raise
      when .string?
        if kind(1).dot?
          parse_column_path
        else
          advance
          Literal.new(LiteralKind::String, text(token))
        end
      else
        syntax_error unless idj?(token.kind)
        if kind(1).left_paren?
          parse_function_call
        elsif kind(1).dot?
          parse_column_path
        else
          advance
          ColumnReference.new(nil, nil, name_of(token))
        end
      end
    end

    private def parse_parenthesized : Expression
      expect(TokenKind::LeftParen)
      if select_start?
        query = parse_select
        expect(TokenKind::RightParen)
        return measured(ScalarSubquery.new(query), query.expression_height)
      end
      first = parse_expression
      if kind.comma?
        elements = [first]
        while accept(TokenKind::Comma)
          elements << parse_expression
        end
        expect(TokenKind::RightParen)
        return measured(RowValue.new(elements), elements.max_of(&.height))
      end
      expect(TokenKind::RightParen)
      first
    end

    private def select_start? : Bool
      kind.select? || kind.values? || kind.with?
    end

    # `nm . nm` or `nm . nm . nm`.
    private def parse_column_path : Expression
      first = parse_nm
      expect(TokenKind::Dot)
      second = parse_nm
      if accept(TokenKind::Dot)
        third = parse_nm
        return measured(ColumnReference.new(first, second, third), 2)
      end
      measured(ColumnReference.new(nil, first, second), 1)
    end

    # util.c, sqlite3DequoteNumber: every `_` stands between two digits.
    private def parse_quoted_number : Expression
      token = advance
      raw = text(token)
      hex = raw.size > 1 && raw[0] == '0' && raw[1].in?('x', 'X')
      raw.each_char_with_index do |char, index|
        next unless char == '_'
        before = index > 0 ? raw[index - 1] : ' '
        after = index + 1 < raw.size ? raw[index + 1] : ' '
        valid = hex ? (before.hex? && after.hex?) : (before.ascii_number? && after.ascii_number?)
        raise ParseError.new(%(unrecognized token: "#{raw}"), token.start) unless valid
      end
      float = !hex && raw.each_char.any?(&.in?('.', 'e', 'E'))
      Literal.new(float ? LiteralKind::Float : LiteralKind::Integer, raw)
    end

    private def current_time_literal(token : Token) : Literal
      raw = text(token)
      kind = case raw.upcase
             when "CURRENT_DATE" then LiteralKind::CurrentDate
             when "CURRENT_TIME" then LiteralKind::CurrentTime
             else                     LiteralKind::CurrentTimestamp
             end
      Literal.new(kind, raw)
    end

    # sqlite3ExprAssignVarNumber.
    private def parse_parameter : Expression
      token = advance
      raw = text(token)
      number = case raw[0]
               when '?'
                 if raw.size == 1
                   @parameter_count += 1
                 else
                   value = raw[1..].to_i64?
                   if value.nil? || value < 1 || value > Limits::MAX_VARIABLE_NUMBER
                     raise ParseError.new("variable number must be between ?1 and ?#{Limits::MAX_VARIABLE_NUMBER}", token.start)
                   end
                   @parameter_count = value.to_i32 if value > @parameter_count
                   value.to_i32
                 end
               else
                 syntax_error(token) if raw[0] == '#' && raw.size > 1 && raw[1].ascii_number?
                 @named_parameters[raw]? || (@named_parameters[raw] = (@parameter_count += 1))
               end
      if number > Limits::MAX_VARIABLE_NUMBER
        raise ParseError.new("too many SQL variables", token.start)
      end
      Parameter.new(raw, number)
    end

    private def parse_cast : Expression
      advance
      expect(TokenKind::LeftParen)
      operand = parse_expression
      expect(TokenKind::As)
      type_name = parse_type_name
      expect(TokenKind::RightParen)
      measured(Cast.new(operand, type_name), operand.height)
    end

    # parse.y's typetoken: words, then up to two signed numbers in
    # parentheses. Nil when no type is written.
    private def parse_type_name : TypeName?
      return unless ids?
      start = peek.start
      words = [] of Name
      last = peek
      while ids?
        last = advance
        words << name_of(last)
      end
      arguments = [] of String
      if accept(TokenKind::LeftParen)
        arguments << parse_signed_number
        arguments << parse_signed_number if accept(TokenKind::Comma)
        last = expect(TokenKind::RightParen)
      end
      type_name = TypeName.new(words, arguments)
      type_name.source_text = @tokenizer.span(start, last.start + last.size)
      type_name
    end

    # parse.y's `signed`: `[+|-] INTEGER|FLOAT`.
    private def parse_signed_number : String
      sign = ""
      if kind.plus? || kind.minus?
        sign = text(advance)
      end
      syntax_error unless kind.integer? || kind.float?
      sign + text(advance)
    end

    private def parse_case : Expression
      expect(TokenKind::Case)
      operand = kind.when? ? nil : parse_expression
      branches = [] of CaseBranch
      height = operand ? operand.height : 0
      expect(TokenKind::When)
      loop do
        condition = parse_expression
        expect(TokenKind::Then)
        result = parse_expression
        height = {height, condition.height, result.height}.max
        branches << CaseBranch.new(condition, result)
        break unless accept(TokenKind::When)
      end
      else_result = accept(TokenKind::Else) ? parse_expression : nil
      height = Math.max(height, else_result.height) if else_result
      expect(TokenKind::End)
      measured(CaseExpression.new(operand, branches, else_result), height)
    end

    private def parse_raise : Expression
      expect(TokenKind::Raise)
      expect(TokenKind::LeftParen)
      if accept(TokenKind::Ignore)
        expect(TokenKind::RightParen)
        return Raise.new(RaiseAction::Ignore, nil)
      end
      action = case kind
               when .rollback? then RaiseAction::Rollback
               when .abort?    then RaiseAction::Abort
               when .fail?     then RaiseAction::Fail
               else                 syntax_error
               end
      advance
      expect(TokenKind::Comma)
      message = parse_expression
      expect(TokenKind::RightParen)
      measured(Raise.new(action, message), message.height)
    end

    private def parse_function_call : Expression
      name_token = advance
      name = name_of(name_token)
      expect(TokenKind::LeftParen)
      distinct = DistinctMode::None
      arguments = [] of Expression
      order_by = [] of OrderingTerm
      star = false
      if accept(TokenKind::Star)
        star = true
      else
        if accept(TokenKind::Distinct)
          distinct = DistinctMode::Distinct
        elsif accept(TokenKind::All)
          distinct = DistinctMode::All
        end
        arguments = parse_expression_list unless kind.right_paren? || kind.order?
        if accept(TokenKind::Order)
          expect(TokenKind::By)
          order_by = parse_ordering_terms
        end
      end
      expect(TokenKind::RightParen)
      if arguments.size > Limits::MAX_FUNCTION_ARGUMENTS
        action_error(%(too many arguments on function #{text(name_token)}))
      end
      height = arguments.max_of?(&.height) || 0
      filter = nil
      if kind.filter?
        advance
        expect(TokenKind::LeftParen)
        expect(TokenKind::Where)
        filter = parse_expression
        expect(TokenKind::RightParen)
      end
      over = nil
      over_name = nil
      if accept(TokenKind::Over)
        if accept(TokenKind::LeftParen)
          over = parse_window
          expect(TokenKind::RightParen)
        else
          over_name = parse_nm
        end
      end
      if distinct.distinct? && (over || over_name)
        action_error("DISTINCT is not supported for window functions")
      end
      measured(FunctionCall.new(name, distinct, arguments, star, order_by, filter, over, over_name), height)
    end

    # parse.y's window: `[base] [PARTITION BY ...] [ORDER BY ...] [frame]`.
    private def parse_window : Window
      base = nil
      if nm? && !(kind.partition? || kind.range? || kind.rows? || kind.groups?)
        base = parse_nm
      end
      partition_by = [] of Expression
      if accept(TokenKind::Partition)
        expect(TokenKind::By)
        partition_by = parse_expression_list
      end
      order_by = [] of OrderingTerm
      if accept(TokenKind::Order)
        expect(TokenKind::By)
        order_by = parse_ordering_terms
      end
      frame = kind.range? || kind.rows? || kind.groups? ? parse_frame : nil
      Window.new(base, partition_by, order_by, frame)
    end

    private def parse_frame : Frame
      unit = case advance.kind
             when .range? then FrameUnit::Range
             when .rows?  then FrameUnit::Rows
             else              FrameUnit::Groups
             end
      finish = nil
      if accept(TokenKind::Between)
        start = parse_frame_bound(starting: true)
        expect(TokenKind::And)
        finish = parse_frame_bound(starting: false)
      else
        start = parse_frame_bound(starting: true)
      end
      exclude = FrameExclude::None
      if accept(TokenKind::Exclude)
        exclude = case kind
                  when .no?      then advance; expect(TokenKind::Others); FrameExclude::NoOthers
                  when .current? then advance; expect(TokenKind::Row); FrameExclude::CurrentRow
                  when .group?   then advance; FrameExclude::Group
                  when .ties?    then advance; FrameExclude::Ties
                  else                syntax_error
                  end
      end
      end_kind = finish ? finish.kind : FrameBoundKind::CurrentRow
      if (start.kind.current_row? && end_kind.preceding?) ||
         (start.kind.following? && (end_kind.preceding? || end_kind.current_row?))
        action_error("unsupported frame specification")
      end
      Frame.new(unit, start, finish, exclude)
    end

    private def parse_frame_bound(starting : Bool) : FrameBound
      if accept(TokenKind::Unbounded)
        if starting
          expect(TokenKind::Preceding)
          return FrameBound.new(FrameBoundKind::UnboundedPreceding, nil)
        end
        expect(TokenKind::Following)
        return FrameBound.new(FrameBoundKind::UnboundedFollowing, nil)
      end
      if accept(TokenKind::Current)
        expect(TokenKind::Row)
        return FrameBound.new(FrameBoundKind::CurrentRow, nil)
      end
      offset = parse_expression
      if accept(TokenKind::Preceding)
        FrameBound.new(FrameBoundKind::Preceding, offset)
      else
        expect(TokenKind::Following)
        FrameBound.new(FrameBoundKind::Following, offset)
      end
    end

    # `expr, expr, ...` (parse.y nexprlist).
    private def parse_expression_list : Array(Expression)
      expressions = [parse_expression]
      while accept(TokenKind::Comma)
        expressions << parse_expression
      end
      expressions
    end

    # parse.y's sortlist: `expr [ASC|DESC] [NULLS FIRST|LAST], ...`.
    private def parse_ordering_terms : Array(OrderingTerm)
      terms = [] of OrderingTerm
      loop do
        expression = parse_expression
        order = SortOrder::None
        if accept(TokenKind::Asc)
          order = SortOrder::Asc
        elsif accept(TokenKind::Desc)
          order = SortOrder::Desc
        end
        nulls = NullsOrder::None
        if accept(TokenKind::Nulls)
          if accept(TokenKind::First)
            nulls = NullsOrder::First
          else
            expect(TokenKind::Last)
            nulls = NullsOrder::Last
          end
        end
        terms << OrderingTerm.new(expression, order, nulls)
        break unless accept(TokenKind::Comma)
      end
      terms
    end

    # Sets a node's height to one more than its tallest child, and raises
    # SQLite's error when that passes the limit (sqlite3ExprCheckHeight).
    private def measured(node : Expression, child_height : Int32) : Expression
      height = child_height + 1
      if height > Limits::MAX_EXPRESSION_DEPTH
        action_error("Expression tree is too large (maximum depth #{Limits::MAX_EXPRESSION_DEPTH})")
      end
      node.height = height
      node
    end

    private def measured(node : Expression, first_height : Int32, second_height : Int32) : Expression
      measured(node, Math.max(first_height, second_height))
    end
  end
end
