module Grant::SQLiteEngine::SQL
  # SELECT and the clauses DML shares with it (lang_select.html, parse.y
  # query through limit_opt).
  module SelectParsing
    # One SELECT or VALUES core with the ORDER BY and LIMIT written after it.
    private record CoreWithTail, core : SelectCore, order_by : Array(OrderingTerm), limit : Limit?, height : Int32

    # `[WITH ...] core [compound core]... [ORDER BY ...] [LIMIT ...]`.
    private def parse_select(with_clause : WithClause? = nil) : SelectStatement
      nested do
        if with_clause.nil? && kind.with?
          with_clause = parse_with_clause
        end
        parts = [parse_select_core]
        operators = [] of CompoundOperator
        while operator = parse_compound_operator
          operators << operator
          parts << parse_select_core
        end
        check_compound(parts, operators)
        last = parts.last
        query = SelectStatement.new(with_clause, parts.map(&.core), operators, last.order_by, last.limit)
        query.expression_height = parts.max_of(&.height)
        query
      end
    end

    # parse.y's parserDoubleLinkSelect: ORDER BY and LIMIT belong after the
    # last core, and a compound has at most 500 terms.
    private def check_compound(parts : Array(CoreWithTail), operators : Array(CompoundOperator)) : Nil
      return if parts.size == 1
      (parts.size - 2).downto(0) do |index|
        part = parts[index]
        next if part.order_by.empty? && part.limit.nil?
        clause = part.order_by.empty? ? "LIMIT" : "ORDER BY"
        action_error("#{clause} clause should come after #{compound_name(operators[index])} not before")
      end
      if parts.size > Limits::MAX_COMPOUND_SELECT && !parts.last.core.is_a?(ValuesClause)
        action_error("too many terms in compound SELECT")
      end
    end

    private def compound_name(operator : CompoundOperator) : String
      case operator
      when .union_all? then "UNION ALL"
      when .intersect? then "INTERSECT"
      when .except?    then "EXCEPT"
      else                  "UNION"
      end
    end

    private def parse_compound_operator : CompoundOperator?
      case kind
      when .union?
        advance
        accept(TokenKind::All) ? CompoundOperator::UnionAll : CompoundOperator::Union
      when .intersect? then advance; CompoundOperator::Intersect
      when .except?    then advance; CompoundOperator::Except
      end
    end

    private def parse_select_core : CoreWithTail
      if kind.values?
        rows, height = parse_values_rows
        return CoreWithTail.new(ValuesClause.new(rows), [] of OrderingTerm, nil, height)
      end
      expect(TokenKind::Select)
      distinct = DistinctMode::None
      if accept(TokenKind::Distinct)
        distinct = DistinctMode::Distinct
      elsif accept(TokenKind::All)
        distinct = DistinctMode::All
      end
      columns, height = parse_result_columns
      from = accept(TokenKind::From) ? parse_from : nil
      where = accept(TokenKind::Where) ? parse_expression : nil
      group_by = [] of Expression
      if accept(TokenKind::Group)
        expect(TokenKind::By)
        group_by = parse_expression_list
      end
      having = accept(TokenKind::Having) ? parse_expression : nil
      windows = [] of WindowDefinition
      if accept(TokenKind::Window)
        loop do
          name = parse_nm
          expect(TokenKind::As)
          expect(TokenKind::LeftParen)
          windows << WindowDefinition.new(name, parse_window)
          expect(TokenKind::RightParen)
          break unless accept(TokenKind::Comma)
        end
      end
      order_by = parse_order_by
      limit = parse_limit
      height = Math.max(height, where.height) if where
      height = Math.max(height, having.height) if having
      group_by.each { |expression| height = Math.max(height, expression.height) }
      order_by.each { |term| height = Math.max(height, term.expression.height) }
      if limit
        limit_height = limit.count.height
        if offset = limit.offset
          limit_height = Math.max(limit_height, offset.height)
        end
        height = Math.max(height, limit_height + 1)
      end
      core = SelectClause.new(distinct, columns, from, where, group_by, having, windows)
      CoreWithTail.new(core, order_by, limit, height)
    end

    # `VALUES (row), (row), ...`, every row the same width. insert.c's
    # sqlite3MultiValues checks constant rows read through a co-routine as
    # they are parsed and other rows when names are resolved; a trigger body
    # is never resolved while being created, so there only the first check
    # applies.
    private def parse_values_rows : {Array(Array(Expression)), Int32}
      expect(TokenKind::Values)
      rows = [] of Array(Expression)
      height = 0
      coroutine_width = nil
      loop do
        expect(TokenKind::LeftParen)
        row = parse_expression_list
        expect(TokenKind::RightParen)
        if (previous = rows.last?) && !@in_trigger
          action_error("all VALUES must have the same number of terms") if row.size != previous.size
        elsif previous = rows.last?
          if @has_with || !row.all? { |expression| row_constant?(expression) } ||
             (coroutine_width.nil? && !previous.all? { |expression| row_constant?(expression) && !has_affinity?(expression) })
            coroutine_width = nil
          else
            coroutine_width ||= previous.size
            action_error("all VALUES must have the same number of terms") if row.size != coroutine_width
          end
        end
        row.each { |expression| height = Math.max(height, expression.height) }
        rows << row
        break unless kind.comma? && kind(1).left_paren?
        advance
      end
      {rows, height}
    end

    # expr.c, sqlite3ExprIsConstant before name resolution: no column (TRUE
    # and FALSE excepted), function or subquery.
    private def row_constant?(expression : Expression) : Bool
      case expression
      when ColumnReference
        expression.table.nil? && (expression.column.text.compare("true", case_insensitive: true) == 0 ||
          expression.column.text.compare("false", case_insensitive: true) == 0)
      when FunctionCall, ScalarSubquery, Exists, InSelect, InTable
        false
      when Literal, Parameter, Raise then true
      when UnaryOperation            then row_constant?(expression.operand)
      when BinaryOperation           then row_constant?(expression.left) && row_constant?(expression.right)
      when LikeOperation
        row_constant?(expression.operand) && row_constant?(expression.pattern) &&
          ((escape = expression.escape).nil? || row_constant?(escape))
      when NullTest then row_constant?(expression.operand)
      when Between
        row_constant?(expression.operand) && row_constant?(expression.low) && row_constant?(expression.high)
      when InList then row_constant?(expression.operand) && expression.values.all? { |value| row_constant?(value) }
      when CaseExpression
        ((operand = expression.operand).nil? || row_constant?(operand)) &&
          expression.branches.all? { |branch| row_constant?(branch.condition) && row_constant?(branch.result) } &&
          ((else_result = expression.else_result).nil? || row_constant?(else_result))
      when Cast, Collate then row_constant?(expression.operand)
      when RowValue      then expression.elements.all? { |element| row_constant?(element) }
      else                    true
      end
    end

    # expr.c, sqlite3ExprAffinity on an unresolved expression: only a CAST
    # (seen through COLLATE, or first in a row value) has one.
    private def has_affinity?(expression : Expression) : Bool
      case expression
      when Cast     then true
      when Collate  then has_affinity?(expression.operand)
      when RowValue then has_affinity?(expression.elements.first)
      else               false
      end
    end

    private def parse_order_by : Array(OrderingTerm)
      return [] of OrderingTerm unless accept(TokenKind::Order)
      expect(TokenKind::By)
      parse_ordering_terms
    end

    # `LIMIT count [OFFSET offset]` or `LIMIT offset, count`.
    private def parse_limit : Limit?
      return nil unless accept(TokenKind::Limit)
      first = parse_expression
      if accept(TokenKind::Offset)
        Limit.new(first, parse_expression, false)
      elsif accept(TokenKind::Comma)
        Limit.new(parse_expression, first, true)
      else
        Limit.new(first, nil, false)
      end
    end

    # The result columns, and the height of the tallest expression.
    private def parse_result_columns : {Array(ResultColumn), Int32}
      columns = [] of ResultColumn
      height = 0
      loop do
        if accept(TokenKind::Star)
          columns << AllColumns.new(nil)
        elsif nm? && kind(1).dot? && kind(2).star?
          table = parse_nm
          advance
          advance
          columns << AllColumns.new(table)
        else
          expression = parse_expression
          height = Math.max(height, expression.height)
          columns << ExpressionColumn.new(expression, parse_alias)
        end
        break unless accept(TokenKind::Comma)
      end
      {columns, height}
    end

    # parse.y's `as`: `AS nm`, a bare ID or STRING, or nothing.
    private def parse_alias : Name?
      if accept(TokenKind::As)
        parse_nm
      elsif ids?
        name_of(advance)
      end
    end

    # `WITH [RECURSIVE] name [(columns)] AS [[NOT] MATERIALIZED] (query), ...`.
    private def parse_with_clause : WithClause
      expect(TokenKind::With)
      recursive = accept(TokenKind::Recursive)
      tables = [] of CommonTableExpression
      loop do
        name = parse_nm
        @has_with = true
        if tables.any? { |table| table.name.same?(name.value) }
          action_error("duplicate WITH table name: #{name.value}")
        end
        columns = kind.left_paren? ? parse_eidlist : nil
        expect(TokenKind::As)
        materialization = Materialization::Default
        if accept(TokenKind::Materialized)
          materialization = Materialization::Materialized
        elsif kind.not? && kind(1).materialized?
          advance
          advance
          materialization = Materialization::NotMaterialized
        end
        expect(TokenKind::LeftParen)
        query = parse_select
        expect(TokenKind::RightParen)
        tables << CommonTableExpression.new(name, columns, materialization, query)
        break unless accept(TokenKind::Comma)
      end
      WithClause.new(recursive, tables)
    end

    private def parse_from : From
      nested do
        items = [] of FromItem
        join = nil
        loop do
          items << parse_from_item(join, items.empty?)
          join = parse_join_operator
          break unless join
        end
        From.new(items)
      end
    end

    private def parse_from_item(join : JoinOperator?, first : Bool) : FromItem
      source = if accept(TokenKind::LeftParen)
                 if select_start?
                   query = parse_select
                   expect(TokenKind::RightParen)
                   SubquerySource.new(query, parse_alias)
                 else
                   inner = parse_from
                   expect(TokenKind::RightParen)
                   NestedJoin.new(inner, parse_alias)
                 end
               else
                 schema, name = parse_qualified_name
                 if accept(TokenKind::LeftParen)
                   arguments = kind.right_paren? ? [] of Expression : parse_expression_list
                   expect(TokenKind::RightParen)
                   TableFunction.new(schema, name, arguments, parse_alias)
                 else
                   alias_name = parse_alias
                   indexed_by, not_indexed = parse_indexed_by
                   TableReference.new(schema, name, alias_name, indexed_by, not_indexed)
                 end
               end
      on = nil
      using = nil
      if accept(TokenKind::On)
        on = parse_expression
      elsif accept(TokenKind::Using)
        using = parse_name_list
      end
      if first && (on || using)
        action_error("a JOIN clause is required before #{on ? "ON" : "USING"}")
      end
      FromItem.new(join, source, on, using)
    end

    # `INDEXED BY name` or `NOT INDEXED`.
    private def parse_indexed_by : {Name?, Bool}
      if accept(TokenKind::Indexed)
        expect(TokenKind::By)
        {parse_nm, false}
      elsif kind.not? && kind(1).indexed?
        advance
        advance
        {nil, true}
      else
        {nil, false}
      end
    end

    JOIN_KEYWORD_FLAGS = {
      "NATURAL" => 0x01, "LEFT" => 0x08 | 0x20, "OUTER" => 0x20,
      "RIGHT" => 0x10 | 0x20, "FULL" => 0x08 | 0x10 | 0x20, "INNER" => 0x02, "CROSS" => 0x02 | 0x04,
    }

    # A comma or `[keyword [keyword [keyword]]] JOIN`, checked as
    # query.c's sqlite3JoinType does.
    private def parse_join_operator : JoinOperator?
      if accept(TokenKind::Comma)
        return JoinOperator.new(true, [] of String)
      end
      if accept(TokenKind::Join)
        return JoinOperator.new(false, [] of String)
      end
      return nil unless kind.join_keyword?
      words = [text(advance)]
      2.times do
        break if kind.join?
        syntax_error unless nm?
        words << text(advance)
      end
      expect(TokenKind::Join)
      flags = 0
      error = false
      words.each do |word|
        if flag = JOIN_KEYWORD_FLAGS[word.upcase]?
          flags |= flag
        else
          error = true
          break
        end
      end
      if error || (flags & 0x22) == 0x22 || (flags & 0x38) == 0x20
        action_error("unknown join type: #{words.join(' ')}")
      end
      JoinOperator.new(false, words.map(&.upcase))
    end
  end
end
