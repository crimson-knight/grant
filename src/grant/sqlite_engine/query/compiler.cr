module Grant::SQLiteEngine::Query
  # A compiled SELECT: the producer of its rows and what a caller needs to
  # read them.
  class CompiledSelect
    getter producer : Producer
    getter list_of_column_names : Array(String)
    getter slot_count : Int32
    getter aggregate_count : Int32
    # True when the top level has an ORDER BY, so row order is defined.
    getter? ordered : Bool

    def initialize(@producer : Producer, @list_of_column_names : Array(String), @slot_count : Int32,
                   @aggregate_count : Int32, @ordered : Bool)
    end
  end

  # One compiled query level: its producer, result column names, and the
  # result expressions of its first core. *list_of_affinities* is what a
  # scalar subquery or IN (SELECT) compares with (sqlite3ExprAffinity of the
  # rightmost core's columns); *list_of_column_affinities* is the affinity
  # of the columns a FROM subquery exposes (sqlite3SubqueryColumnTypes);
  # *flattened* says SQLite reads such a subquery's columns straight from
  # its expressions (a UNION ALL compound), without REAL affinity.
  record QueryPlan, producer : Producer, list_of_column_names : Array(String),
    list_of_first_core_columns : Array(Expr), list_of_collations : Array(Collation),
    list_of_affinities : Array(ExpressionAffinity), outer_slots : Set(Int32),
    list_of_column_affinities : Array(ExpressionAffinity), flattened : Bool = false,
    list_of_subquery_names : Array(String)? = nil

  # Turns a SELECT syntax tree into a tree of producers, row sources and
  # expressions, resolving every name the way SQLite's resolve.c does and
  # raising C SQLite's messages for what it rejects.
  class Compiler
    include ExpressionCompiler

    # A recursive CTE stops after this many rows (plan section 4: SQLite
    # itself has no limit).
    RECURSIVE_ROW_BUDGET = 10_000_000_i64

    @slot_count = 0
    @aggregate_count = 0

    def initialize(@session : Session)
    end

    def compile(statement : SQL::SelectStatement) : CompiledSelect
      plan = compile_query(statement, nil, nil)
      CompiledSelect.new(plan.producer, plan.list_of_column_names, @slot_count, @aggregate_count,
        !statement.order_by.empty?)
    end

    protected def allocate_slot : Int32
      slot = @slot_count
      @slot_count += 1
      slot
    end

    protected def allocate_aggregate : Int32
      index = @aggregate_count
      @aggregate_count += 1
      index
    end

    # Compiles a whole SELECT (WITH, cores, compound operators, ORDER BY,
    # LIMIT) as a query nested in *parent* (nil at the top level).
    protected def compile_query(statement : SQL::SelectStatement, parent : QueryContext?, ctes : CteScope?) : QueryPlan
      scope = ctes
      if with_clause = statement.with_clause
        scope = CteScope.new(ctes)
        with_clause.tables.each do |table|
          name = table.name.value
          if scope.list_of_definitions.any? { |definition| definition.name.compare(name, case_insensitive: true) == 0 }
            raise SQLError.new("duplicate WITH table name: #{name}")
          end
          columns = table.columns.try(&.map(&.value))
          scope.list_of_definitions << CteDefinition.new(name, columns, table.query, with_clause.recursive, scope)
        end
      end
      @query_depth += 1
      begin
        if statement.cores.size == 1
          compile_single(statement, statement.cores[0], parent, scope)
        else
          compile_compound(statement, parent, scope)
        end
      ensure
        @query_depth -= 1
      end
    end

    # The name errors recorded while resolving the current expression
    # (ExpressionCompiler#resolve_expression); nil when none is.
    @list_of_name_errors : Array(SQLError)? = nil

    # How many compile_query calls are active: tells a recursive CTE's
    # own FROM reference from one inside a subquery.
    @query_depth = 0

    private def compile_single(statement : SQL::SelectStatement, core : SQL::SelectCore, parent : QueryContext?,
                               ctes : CteScope?) : QueryPlan
      context = QueryContext.new(parent, @slot_count, ctes)
      # resolveSelectStep resolves LIMIT and OFFSET before anything else.
      limit = compile_limit(statement.limit, context)
      core_plan = compile_core(core, context, statement.order_by)
      producer = core_plan.producer
      unless statement.order_by.empty?
        producer = SortProducer.new(producer, core_plan.list_of_sort_keys, core_plan.list_of_columns.size)
      end
      producer = LimitProducer.new(producer, limit[0], limit[1]) if limit
      propagate_correlation(context, parent)
      QueryPlan.new(producer, core_plan.list_of_names, core_plan.list_of_columns,
        core_plan.list_of_columns.map { |column| column.collation_sequence || Collation::Binary },
        core_plan.list_of_columns.map(&.affinity), context.outer_slots, core_plan.list_of_columns.map(&.affinity),
        list_of_subquery_names: core_plan.list_of_subquery_names)
    end

    private def apply_limit(producer : Producer, limit : SQL::Limit?, context : QueryContext) : Producer
      compiled = compile_limit(limit, context)
      compiled ? LimitProducer.new(producer, compiled[0], compiled[1]) : producer
    end

    # The LIMIT count and OFFSET of *limit*, compiled.
    private def compile_limit(limit : SQL::Limit?, context : QueryContext) : {Expr, Expr?}?
      return unless limit
      saved = context.aliases_visible?
      context.aliases_visible = false
      count = compile_expression(limit.count, context)
      offset = limit.offset.try { |expression| compile_expression(expression, context) }
      context.aliases_visible = saved
      # The parser stores `LIMIT a, b` as count b, offset a.
      {count, offset}
    end

    # A correlated reference inside a nested query also makes the enclosing
    # query correlated when it reaches past that query too.
    private def propagate_correlation(context : QueryContext, parent : QueryContext?) : Nil
      return unless parent
      context.outer_slots.each do |slot|
        next if parent.owns_slot?(slot)
        parent.correlated = true
        parent.outer_slots << slot
      end
    end

    private def compile_compound(statement : SQL::SelectStatement, parent : QueryContext?, ctes : CteScope?) : QueryPlan
      plans = [] of CorePlan
      contexts = [] of QueryContext
      statement.cores.each do |core|
        context = QueryContext.new(parent, @slot_count, ctes)
        plan = compile_core(core, context, [] of SQL::OrderingTerm)
        if (first = plans.first?) && first.list_of_columns.size != plan.list_of_columns.size
          raise SQLError.new("SELECTs to the left and right of #{operator_word(statement.operators[plans.size - 1])} do not have the same number of result columns")
        end
        plans << plan
        contexts << context
      end
      width = plans[0].list_of_columns.size
      collations = (0...width).map { |index| compound_collation(plans, index) }
      # convertCompoundSelectToSubquery: a compound with an operator other
      # than UNION ALL and a COLLATE in its ORDER BY runs as
      # `SELECT * FROM (compound) ORDER BY ...`: the compound itself is
      # unordered, its column names are made unique, and its REAL columns
      # read back with REAL affinity.
      wrapped = !statement.order_by.empty? && statement.operators.any? { |operator| !operator.union_all? } &&
                statement.order_by.any? { |term| contains_collate?(term.expression) }
      column_affinities = compound_column_affinities(plans)
      ordered = !statement.order_by.empty? && !wrapped
      keys = statement.order_by.map_with_index { |term, index| compound_sort_key(term, index, plans, contexts, wrapped ? leftmost_collations(plans) : collations) }
      merge_keys = keys + (0...width).reject { |index| keys.any? { |key| key.position == index } }.map do |index|
        SortKey.new(index, collations[index], false, true)
      end
      producer = CompoundProducer.new(plans.map(&.producer), statement.operators, collations,
        ordered: ordered, list_of_merge_keys: ordered ? merge_keys : [] of SortKey).as(Producer)
      if wrapped && column_affinities.any?(&.real?)
        producer = RealAffinityProducer.new(producer, column_affinities.map(&.real?))
      end
      # sqlite3SubqueryColumnTypes takes a subquery column's collation from
      # the leftmost SELECT only (multiSelectCollSeq, which looks further
      # right, is for the compound's own comparisons).
      leftmost_collations = leftmost_collations(plans)
      producer = SortProducer.new(producer, keys, width) unless keys.empty?
      producer = apply_limit(producer, statement.limit, contexts[0])
      contexts.each { |context| propagate_correlation(context, parent) }
      names = plans[0].list_of_names
      names = Compiler.unique_names(plans[0].list_of_subquery_names) if wrapped
      QueryPlan.new(producer, names, plans[0].list_of_columns, leftmost_collations,
        plans.last.list_of_columns.map(&.affinity), contexts.reduce(Set(Int32).new) { |all, context| all | context.outer_slots },
        column_affinities, statement.operators.all?(&.union_all?), plans[0].list_of_subquery_names)
    end

    private def leftmost_collations(plans : Array(CorePlan)) : Array(Collation)
      plans[0].list_of_columns.map { |column| column.collation_sequence || Collation::Binary }
    end

    private def operator_word(operator : SQL::CompoundOperator) : String
      case operator
      in .union?     then "UNION"
      in .union_all? then "UNION ALL"
      in .intersect? then "INTERSECT"
      in .except?    then "EXCEPT"
      end
    end

    # multiSelectCollSeq: the leftmost core whose column has a collation.
    private def compound_collation(plans : Array(CorePlan), index : Int32) : Collation
      plans.each do |plan|
        if collation = plan.list_of_columns[index].collation_sequence
          return collation
        end
      end
      Collation::Binary
    end

    # The affinity of a compound's columns as a subquery sees them: the
    # leftmost core's, unless a later core disagrees, which gives BLOB.
    # sqlite3SubqueryColumnTypes for a compound: the leftmost core's column
    # affinity (or, without one, the next core's that has one); a TEXT
    # column becomes BLOB when a later core can produce a number, a numeric
    # one BLOB when a later core can produce text, and FLEXNUM when the
    # leftmost expression is a CAST.
    private def compound_column_affinities(plans : Array(CorePlan)) : Array(ExpressionAffinity)
      plans[0].list_of_columns.map_with_index do |first, index|
        mask = 0
        position = 0
        affinity = first.affinity
        while !affinity.any? && position + 1 < plans.size
          mask |= plans[position].list_of_columns[index].data_type
          position += 1
          affinity = plans[position].list_of_columns[index].affinity
        end
        if affinity >= ExpressionAffinity::Text && plans.size > 1
          ((position + 1)...plans.size).each { |later| mask |= plans[later].list_of_columns[index].data_type }
          if affinity.text? && mask & 0x01 != 0
            affinity = ExpressionAffinity::Blob
          elsif affinity.numeric? && mask & 0x02 != 0
            affinity = ExpressionAffinity::Blob
          end
          affinity = ExpressionAffinity::FlexNum if affinity.numeric? && first.is_a?(CastExpr)
        end
        affinity
      end
    end

    # True when a COLLATE appears in *expression* outside subqueries (the
    # EP_Collate flag).
    private def contains_collate?(expression : SQL::Expression) : Bool
      return true if expression.is_a?(SQL::Collate)
      return false if expression.is_a?(SQL::ScalarSubquery) || expression.is_a?(SQL::Exists)
      children_of(expression).any? { |child| contains_collate?(child) }
    end

    # A compound's ORDER BY term must name a result column: by number, by
    # alias, or by matching a result expression (resolveCompoundOrderBy).
    private def compound_sort_key(term : SQL::OrderingTerm, index : Int32, plans : Array(CorePlan), contexts : Array(QueryContext),
                                  collations : Array(Collation)) : SortKey
      width = plans[0].list_of_columns.size
      expression = term.expression
      explicit = nil
      # The outermost COLLATE names the collation: `1 COLLATE a COLLATE b` is b.
      while expression.is_a?(SQL::Collate)
        explicit ||= collation_named(expression.collation.value)
        expression = expression.operand
      end
      position = integer_term(expression, width, "ORDER", index)
      unless position
        plans.each do |plan|
          break if position
          if expression.is_a?(SQL::ColumnReference) && expression.table.nil?
            position = plan.list_of_aliases.index { |alias_name| alias_name && alias_name.compare(expression.column.value, case_insensitive: true) == 0 }
            break if position
          end
          plan.list_of_syntax.each_with_index do |syntax, column|
            if syntax && syntax == expression
              position = column
              break
            end
          end
        end
      end
      # resolveOrderByTermToExprList: a column reference resolves against
      # each SELECT's FROM and matches a result column naming that column.
      if position.nil? && expression.is_a?(SQL::ColumnReference)
        plans.each_with_index do |plan, plan_index|
          break if position
          resolved = begin
            compile_expression(expression, contexts[plan_index])
          rescue SQLError
            next
          end
          position = plan.list_of_columns.index { |column| same_column?(column, resolved) }
        end
      end
      raise SQLError.new("#{Compiler.ordinal(index + 1)} ORDER BY term does not match any column in the result set") unless position
      sort_key(term, position, explicit || collations[position])
    end

    private def sort_key(term : SQL::OrderingTerm, position : Int32, collation : Collation) : SortKey
      descending = term.order.desc?
      nulls_first = case term.nulls
                    in .first? then true
                    in .last?  then false
                    in .none?  then !descending
                    end
      SortKey.new(position, collation, descending, nulls_first)
    end

    # The 0-based column a constant integer term names, or nil when the term
    # is not an integer constant (sqlite3ExprIsInteger).
    private def integer_term(expression : SQL::Expression, width : Int32, clause : String, index : Int32 = 0) : Int32?
      value = constant_integer(expression)
      return unless value
      if value < 1 || value > width
        raise SQLError.new("#{Compiler.ordinal(index + 1)} #{clause} BY term out of range - should be between 1 and #{width}")
      end
      (value - 1).to_i32
    end

    # printf's %r: 1st, 2nd, 3rd, 4th, ... 11th, 12th, 13th, 21st.
    def self.ordinal(number : Int32) : String
      suffix = if (11..13).includes?(number % 100)
                 "th"
               else
                 case number % 10
                 when 1 then "st"
                 when 2 then "nd"
                 when 3 then "rd"
                 else        "th"
                 end
               end
      "#{number}#{suffix}"
    end

    private def constant_integer(expression : SQL::Expression) : Int64?
      case expression
      when SQL::Literal
        return unless expression.kind.integer?
        literal_integer(expression.text, negative: false).as?(Int64)
      when SQL::UnaryOperation
        operand = expression.operand
        return unless operand.is_a?(SQL::Literal) && operand.kind.integer?
        case expression.operator
        when .negate? then literal_integer(operand.text, negative: true).as?(Int64)
        when .plus?   then literal_integer(operand.text, negative: false).as?(Int64)
        end
      end
    end

    # The result of compiling one SELECT core.
    class CorePlan
      getter producer : Producer
      getter list_of_columns : Array(Expr)
      getter list_of_names : Array(String)
      # The alias of each result column, nil where it has none.
      getter list_of_aliases : Array(String?)
      # The syntax of each result column (nil for `*` expansions).
      getter list_of_syntax : Array(SQL::Expression?)
      getter list_of_sort_keys : Array(SortKey)

      def initialize(@producer : Producer, @list_of_columns : Array(Expr), @list_of_names : Array(String),
                     @list_of_aliases : Array(String?), @list_of_syntax : Array(SQL::Expression?),
                     @list_of_sort_keys : Array(SortKey))
      end

      # sqlite3ColumnsFromExprList: the alias, else the column a result
      # expression names once COLLATE and likely() are skipped, else the
      # name the result column already has (its text).
      def list_of_subquery_names : Array(String)
        @list_of_columns.map_with_index do |column, index|
          alias_name = @list_of_aliases[index]
          next alias_name if alias_name
          inner = column
          while inner.is_a?(CollateExpr) || inner.is_a?(PassThroughExpr)
            inner = inner.children.first
          end
          name = inner.column_name? if inner.is_a?(ColumnExpr) || inner.is_a?(RowidExpr)
          name || @list_of_names[index]
        end
      end
    end

    private def compile_core(core : SQL::SelectCore, context : QueryContext, order_by : Array(SQL::OrderingTerm)) : CorePlan
      if core.is_a?(SQL::ValuesClause)
        return compile_values(core, context, order_by)
      end
      raise UnsupportedSQL.new("#{core.class.name} as a SELECT core") unless core.is_a?(SQL::SelectClause)
      raise UnsupportedSQL.new("WINDOW clause") unless core.windows.empty?
      steps = compile_from(core.from, context)
      # Result columns: `*` and `table.*` expanded.
      syntax = [] of SQL::Expression?
      aliases = [] of String?
      spans = [] of String?
      expanded = [] of Expr
      core.columns.each do |column|
        case column
        when SQL::AllColumns
          expand_star(column, context, expanded, syntax, aliases, spans)
        when SQL::ExpressionColumn
          syntax << column.expression
          aliases << column.alias_name.try(&.value)
          spans << column.span
          expanded << ConstantExpr.new(nil) # placeholder, compiled below
        end
      end
      context.list_of_aliases = [] of {String, SQL::Expression}
      syntax.each_with_index do |expression, index|
        alias_name = aliases[index]
        context.list_of_aliases << {alias_name, expression} if alias_name && expression
      end
      # resolveSelectStep: GROUP BY or an aggregate in the result set makes
      # an aggregate query (HAVING alone does not).
      aggregate = !core.group_by.empty? || core.columns.any? { |column| column.is_a?(SQL::ExpressionColumn) && contains_aggregate?(column.expression) } ||
                  order_by.any? { |term| contains_aggregate?(term.expression) }
      context.aggregate_query = aggregate
      collector = aggregate ? AggregateCollector.new : nil
      # resolveSelectStep's order: the result set, HAVING, WHERE, ORDER BY,
      # then GROUP BY; it decides which unknown name an error reports.
      context.aggregates = collector
      context.aliases_visible = false
      syntax.each_with_index do |expression, index|
        expanded[index] = resolve_expression(expression, context) if expression
      end
      if core.having && !aggregate
        raise SQLError.new("HAVING clause on a non-aggregate query")
      end
      context.aliases_visible = true
      having_expression = core.having.try { |expression| resolve_expression(expression, context) }
      context.aggregates = nil
      # An aggregate query resolves aggregates in WHERE (NC_AllowAgg stays
      # set) and fails only when generating code for them.
      late_error = nil
      where = begin
        core.where.try { |expression| resolve_expression(expression, context) }
      rescue error : ResolveError
        misuse = aggregate ? (error.message || "").match(/\Amisuse of aggregate function (.+)\(\)\z/) : nil
        raise error unless misuse
        late_error = "misuse of aggregate: #{misuse[1]}()"
        nil
      end
      context.aggregates = collector
      names = (0...expanded.size).map { |index| result_name(aliases[index], expanded[index], spans[index], index) }
      sort_keys = [] of SortKey
      extras = [] of Expr
      order_by.each_with_index do |term, term_index|
        expression = term.expression
        explicit = nil
        while expression.is_a?(SQL::Collate)
          explicit ||= collation_named(expression.collation.value)
          expression = expression.operand
        end
        position = integer_term(expression, expanded.size, "ORDER", term_index)
        if position.nil? && expression.is_a?(SQL::ColumnReference) && expression.table.nil?
          position = aliases.index { |alias_name| alias_name && alias_name.compare(expression.column.value, case_insensitive: true) == 0 }
        end
        if position
          key_expression = expanded[position]
        else
          key_expression = resolve_expression(expression, context)
        end
        collation = explicit || key_expression.collation_sequence || Collation::Binary
        extras << key_expression
        sort_keys << sort_key(term, expanded.size + extras.size - 1, collation)
      end
      context.aggregates = nil
      group_keys = [] of Expr
      core.group_by.each_with_index do |term, index|
        if contains_aggregate?(term)
          raise SQLError.new("aggregate functions are not allowed in the GROUP BY clause")
        end
        if position = integer_term(term, syntax.size, "GROUP", index)
          group_syntax = syntax[position]
          if group_syntax && contains_aggregate?(group_syntax)
            raise SQLError.new("aggregate functions are not allowed in the GROUP BY clause")
          end
          group_keys << (group_syntax ? resolve_expression(group_syntax, context) : expanded[position])
        else
          group_keys << resolve_expression(term, context)
        end
      end
      context.aliases_visible = false
      aggregation = nil
      if collector
        key_collations = group_keys.map { |key| key.collation_sequence || Collation::Binary }
        slots = context.list_of_entries.map(&.slot)
        aggregation = Aggregation.new(group_keys, key_collations, collector.list_of_calls, having_expression, slots)
      end
      if collector.nil? && !core.distinct.distinct?
        local = context.list_of_entries.map(&.slot).to_set
        sort_keys = sort_keys.reject do |key|
          term = extras[key.position - expanded.size]?
          term && pinned_by_equality?(term, key.collation, where, local)
        end
      end
      source, where = plan_access(steps, where, context)
      column_collations = expanded.map { |column| column.collation_sequence || Collation::Binary }
      producer = CoreProducer.new(source, where, expanded, extras, aggregation, core.distinct.distinct?, column_collations).as(Producer)
      if table = simple_count_table(core, steps, order_by)
        producer = TableCountProducer.new(@session.database, table)
      end
      raise SQLError.new(late_error) if late_error
      CorePlan.new(producer, expanded, names, aliases, syntax, sort_keys)
    end

    # wherePathSatisfiesOrderBy: an ORDER BY term that is a column a WHERE
    # term pins with `=`, IS or IS NULL to a value from outside this query's
    # FROM needs no sorting (with `=` and IS, when the comparison's
    # collation is the term's). Rows that differ only there keep scan order.
    private def pinned_by_equality?(term : Expr, collation : Collation, where : Expr?, local : Set(Int32)) : Bool
      column = term
      while column.is_a?(CollateExpr) || column.is_a?(PassThroughExpr)
        column = column.children.first
      end
      return false unless column.is_a?(ColumnExpr) || column.is_a?(RowidExpr)
      ExpressionWalk.conjuncts(where).any? do |conjunct|
        if conjunct.is_a?(NullTestExpr)
          !conjunct.negated? && same_column?(conjunct.operand, column)
        elsif conjunct.is_a?(ComparisonExpr) && (conjunct.operator.equal? || conjunct.operator.is?)
          other = if same_column?(conjunct.left, column)
                    conjunct.right
                  elsif same_column?(conjunct.right, column)
                    conjunct.left
                  end
          other && (ExpressionWalk.slots(other) & local).empty? &&
            Query.binary_collation(conjunct.left, conjunct.right) == collation
        else
          false
        end
      end
    end

    private def same_column?(expression : Expr, column : Expr) : Bool
      if expression.is_a?(ColumnExpr) && column.is_a?(ColumnExpr)
        expression.slot == column.slot && expression.column == column.column
      elsif expression.is_a?(RowidExpr) && column.is_a?(RowidExpr)
        expression.slot == column.slot
      else
        false
      end
    end

    # isSimpleCount: one table, no WHERE, GROUP BY or HAVING, and a result
    # that is exactly count(*).
    private def simple_count_table(core : SQL::SelectClause, steps : Array(JoinStep), order_by : Array(SQL::OrderingTerm)) : TableInfo?
      return unless steps.size == 1 && core.where.nil? && core.group_by.empty? && core.having.nil? && order_by.empty?
      return if core.columns.size != 1 || core.distinct.distinct?
      column = core.columns[0]
      return unless column.is_a?(SQL::ExpressionColumn)
      call = column.expression
      return unless call.is_a?(SQL::FunctionCall) && call.star && call.name.value.compare("count", case_insensitive: true) == 0
      return unless call.filter.nil? && call.over.nil? && call.over_name.nil? && call.order_by.empty?
      step = steps[0]
      return if step.left_join?
      step.entry.table
    end

    private def compile_values(core : SQL::ValuesClause, context : QueryContext, order_by : Array(SQL::OrderingTerm)) : CorePlan
      width = core.rows.first.size
      rows = core.rows.map do |row|
        raise SQLError.new("all VALUES must have the same number of terms") unless row.size == width
        row.map { |expression| compile_expression(expression, context) }
      end
      first = rows.first
      names = (1..width).map { |index| "column#{index}" }
      sort_keys = order_by.map_with_index do |term, index|
        position = integer_term(term.expression, width, "ORDER", index)
        raise UnsupportedSQL.new("ORDER BY expression on VALUES") unless position
        sort_key(term, position, Collation::Binary)
      end
      CorePlan.new(ValuesProducer.new(rows), first, names, Array(String?).new(width, nil),
        Array(SQL::Expression?).new(width, nil), sort_keys)
    end

    # generateColumnNames: the alias, else a column's declared name, else
    # the expression's source text.
    private def result_name(alias_name : String?, expression : Expr, span : String?, index : Int32) : String
      return alias_name if alias_name
      if name = expression.column_name?
        return name if expression.is_a?(ColumnExpr) || expression.is_a?(RowidExpr)
      end
      span || "column#{index + 1}"
    end

    private def expand_star(column : SQL::AllColumns, context : QueryContext, expanded : Array(Expr),
                            syntax : Array(SQL::Expression?), aliases : Array(String?), spans : Array(String?)) : Nil
      entries = context.list_of_entries
      if table = column.table
        entry = entries.find { |candidate| candidate.match_name.compare(table.value, case_insensitive: true) == 0 }
        raise SQLError.new("no such table: #{table.value}") unless entry
        entry.list_of_columns.each_with_index { |_, index| append_column(entry, index, expanded, syntax, aliases, spans) }
        return
      end
      raise SQLError.new("no tables specified") if entries.empty?
      entries.each do |entry|
        entry.list_of_columns.each_with_index do |_, index|
          next if entry.merged_columns.includes?(index)
          append_column(entry, index, expanded, syntax, aliases, spans)
        end
      end
    end

    private def append_column(entry : FromEntry, index : Int32, expanded : Array(Expr), syntax : Array(SQL::Expression?),
                              aliases : Array(String?), spans : Array(String?)) : Nil
      expanded << column_expression(entry, index)
      syntax << nil
      aliases << nil
      spans << nil
    end

    protected def column_expression(entry : FromEntry, index : Int32) : Expr
      column = entry.list_of_columns[index]
      ColumnExpr.new(entry.slot, index, column.affinity, column.collation, column.name,
        realify: column.realify && column.affinity.real?)
    end

    protected def rowid_expression(entry : FromEntry) : Expr
      table = entry.table
      name = "rowid"
      if table && (alias_index = table.rowid_alias)
        name = table.list_of_column_names[alias_index]
      end
      RowidExpr.new(entry.slot, name)
    end

    protected def collation_named(name : String) : Collation
      Collation.named?(name) || raise SQLError.new("no such collation sequence: #{name}")
    end
  end
end
