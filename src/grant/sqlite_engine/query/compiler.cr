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
      # sqlite3ErrorMsg keeps the last message.
      if message = @list_of_codegen_errors.last?
        raise SQLError.new(message)
      end
      CompiledSelect.new(plan.producer, plan.list_of_column_names, @slot_count, @aggregate_count,
        !statement.order_by.empty?)
    end

    # Errors C SQLite raises while generating code, after every name of
    # the statement is resolved: the first is raised once compiling ends.
    @list_of_codegen_errors = [] of String

    protected def record_codegen_error(message : String) : Nil
      @list_of_codegen_errors << message
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
      core_plan = compile_core(core, context, statement.order_by, limit_rows(statement.limit))
      producer = core_plan.producer
      unless statement.order_by.empty?
        producer = SortProducer.new(producer, core_plan.list_of_sort_keys, core_plan.list_of_columns.size,
          presorted: core_plan.presorted?)
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

    # selectExpander and resolveSelectStep visit a compound's SELECTs from
    # the rightmost leftward, all of them expanded before any resolves:
    # the rightmost expand-phase error wins, then the rightmost SELECT
    # that fails to resolve or whose width differs from the one to its
    # right.
    private def check_compound_members(statement : SQL::SelectStatement, plans : Array(CorePlan),
                                       list_of_errors : Array(SQLError?)) : Nil
      if expanding = list_of_errors.reverse.find { |error| error && EXPAND_ERROR.matches?(error.message || "") }
        raise expanding
      end
      widths = [] of Int32?
      position = 0
      list_of_errors.each do |error|
        if error
          widths << nil
        else
          widths << plans[position].list_of_columns.size
          position += 1
        end
      end
      (list_of_errors.size - 1).downto(0) do |index|
        if error = list_of_errors[index]
          raise error
        end
        right = widths[index + 1]?
        if right && widths[index] != right
          raise SQLError.new("SELECTs to the left and right of #{operator_word(statement.operators[index])} do not have the same number of result columns")
        end
      end
    end

    private def compile_compound(statement : SQL::SelectStatement, parent : QueryContext?, ctes : CteScope?) : QueryPlan
      plans = [] of CorePlan
      contexts = [] of QueryContext
      list_of_errors = [] of SQLError?
      statement.cores.each do |core|
        context = QueryContext.new(parent, @slot_count, ctes)
        begin
          plans << compile_core(core, context, [] of SQL::OrderingTerm)
          list_of_errors << nil
        rescue error : SQLError
          list_of_errors << error
        end
        contexts << context
      end
      check_compound_members(statement, plans, list_of_errors)
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
        unless explicit
          explicit = collation_named(expression.collation.value)
          if unknown = unknown_collation_name(expression.collation.value)
            record_codegen_error("no such collation sequence: #{unknown}")
          end
        end
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
      # sqlite3ExprIsInteger: only a literal that fits a signed 32-bit
      # integer (or its negation) is a column number; a larger one is an
      # ordinary constant term.
      return unless value && value >= -Int32::MAX.to_i64 && value <= Int32::MAX.to_i64
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
                     @list_of_sort_keys : Array(SortKey), @presorted : Bool = false)
      end

      # True when the core's rows already come in ORDER BY order.
      getter? presorted : Bool

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

    # The most rows a constant LIMIT (and OFFSET) lets the query read past
    # its sort, or nil.
    private def limit_rows(limit : SQL::Limit?) : Float64?
      return unless limit
      count = constant_integer(limit.count)
      return unless count && count >= 0
      offset = limit.offset.try { |expression| constant_integer(expression) } || 0_i64
      return if offset < 0
      count.to_f64 + offset.to_f64
    end

    private def compile_core(core : SQL::SelectCore, context : QueryContext, order_by : Array(SQL::OrderingTerm),
                             limit_rows : Float64? = nil) : CorePlan
      if core.is_a?(SQL::ValuesClause)
        # A one-row VALUES is a SELECT with no FROM (parse.y), so it may
        # aggregate; its columns are still named column1, column2, ...
        if core.rows.size == 1 && core.rows[0].any? { |expression| contains_aggregate?(expression) }
          columns = core.rows[0].map_with_index do |expression, index|
            SQL::ExpressionColumn.new(expression, SQL::Name.bare("column#{index + 1}")).as(SQL::ResultColumn)
          end
          clause = SQL::SelectClause.new(SQL::DistinctMode::None, columns, nil, nil, [] of SQL::Expression, nil,
            [] of SQL::WindowDefinition)
          return compile_core(clause, context, order_by, limit_rows)
        end
        return compile_values(core, context, order_by)
      end
      raise UnsupportedSQL.new("#{core.class.name} as a SELECT core") unless core.is_a?(SQL::SelectClause)
      raise UnsupportedSQL.new("WINDOW clause") unless core.windows.empty?
      codegen_mark = @list_of_codegen_errors.size
      steps = compile_from(core.from, context)
      # countOfViewOptimization turns count(*) over a UNION ALL subquery
      # into a sum of counts of its SELECTs, whose result columns are then
      # never coded: an aggregate there that belongs to an outer query
      # raises no "misuse of aggregate".
      if count_of_view?(core, order_by)
        kept = @list_of_codegen_errors[codegen_mark..].reject(&.starts_with?("misuse of aggregate"))
        @list_of_codegen_errors.truncate(0, codegen_mark)
        @list_of_codegen_errors.concat(kept)
      end
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
      context.aggregate_query = !core.group_by.empty? ||
                                core.columns.any? { |column| column.is_a?(SQL::ExpressionColumn) && contains_aggregate?(column.expression) }
      # resolveSelectStep's order: the result set, HAVING, WHERE, ORDER BY,
      # then GROUP BY; it decides which unknown name an error reports.
      # An aggregate of the result set, including one a subquery there
      # hands up (its arguments read this query's FROM), or GROUP BY makes
      # an aggregate query (HAVING alone does not, nor ORDER BY).
      collector = AggregateCollector.new
      context.aggregates = collector
      context.aggregates_allowed = true
      context.aliases_visible = false
      result_uses = collation_uses do
        syntax.each_with_index do |expression, index|
          expanded[index] = resolve_expression(expression, context) if expression
        end
      end
      aggregate = !core.group_by.empty? || !collector.list_of_calls.empty?
      context.aggregate_query = aggregate
      if core.having && !aggregate
        raise SQLError.new("HAVING clause on a non-aggregate query")
      end
      context.aggregates = aggregate ? collector : nil
      context.aggregates_allowed = aggregate
      context.aliases_visible = true
      having_expression = nil
      having_uses = collation_uses do
        having_expression = core.having.try { |expression| resolve_expression(expression, context) }
      end
      # An aggregate query resolves aggregates in WHERE (NC_AllowAgg stays
      # set) and fails only when generating code for them.
      context.aggregates = nil
      where = nil
      on_reaches_right = false
      where_uses = collation_uses do
        where = core.where.try { |expression| resolve_expression(expression, context) }
        on_reaches_right = compile_join_conditions(steps, context)
      end
      # ORDER BY allows aggregates; in a query that is not an aggregate one
      # they fail when code is generated.
      context.aggregates = aggregate ? collector : nil
      context.aggregates_allowed = true
      names = (0...expanded.size).map { |index| result_name(aliases[index], expanded[index], spans[index], index) }
      sort_keys = [] of SortKey
      sort_unknowns = [] of String?
      extras = [] of Expr
      order_by.each_with_index do |term, term_index|
        expression = term.expression
        explicit = nil
        explicit_unknown = nil
        while expression.is_a?(SQL::Collate)
          unless explicit
            explicit = collation_named(expression.collation.value)
            explicit_unknown = unknown_collation_name(expression.collation.value)
          end
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
        sort_unknowns << (explicit ? explicit_unknown : key_expression.unknown_collation)
        extras << key_expression
        sort_keys << sort_key(term, expanded.size + extras.size - 1, collation)
      end
      context.aggregates = nil
      context.aggregates_allowed = false
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
      # selectCheckOnClauses runs once the whole SELECT has resolved.
      raise SQLError.new("ON clause references tables to its right") if on_reaches_right
      distinct_unknowns = core.distinct.distinct? ? expanded.map(&.unknown_collation) : [] of String?
      record_collation_error(group_keys.map(&.unknown_collation), sort_unknowns, distinct_unknowns,
        [where_uses, having_uses, result_uses])
      aggregation = nil
      if aggregate
        key_collations = group_keys.map { |key| key.collation_sequence || Collation::Binary }
        slots = context.list_of_entries.map(&.slot)
        aggregation = Aggregation.new(group_keys, key_collations, collector.list_of_calls, having_expression, slots)
      end
      if !aggregate && !core.distinct.distinct?
        local = context.list_of_entries.map(&.slot).to_set
        sort_keys = sort_keys.reject do |key|
          term = extras[key.position - expanded.size]?
          term && pinned_by_equality?(term, key.collation, where, local)
        end
      end
      ordering = [] of OrderTerm
      if aggregation
        aggregation.list_of_group_keys.each_with_index do |key, index|
          ordering << OrderTerm.new(key, aggregation.list_of_key_collations[index], false, true)
        end
      else
        sort_keys.each do |key|
          ordering << OrderTerm.new(extras[key.position - expanded.size], key.collation, key.descending, key.nulls_first)
        end
      end
      # Rows stop at the LIMIT only when nothing between the scan and the
      # LIMIT keeps them all (no aggregate, no DISTINCT).
      stopping = aggregation.nil? && !core.distinct.distinct? ? limit_rows : nil
      source, where, ordered = plan_access(steps, where, context, ordering, stopping)
      presorted = aggregation ? groups_give_order?(aggregation, sort_keys, extras, expanded.size) : ordered
      column_collations = expanded.map { |column| column.collation_sequence || Collation::Binary }
      producer = CoreProducer.new(source, where, expanded, extras, aggregation, core.distinct.distinct?, column_collations,
        streaming: !aggregation.nil? && ordered).as(Producer)
      if table = simple_count_table(core, steps, order_by)
        producer = TableCountProducer.new(table.database, table)
      end
      CorePlan.new(producer, expanded, names, aliases, syntax, sort_keys, presorted)
    end

    # Groups come out in ascending key order (sorted, or read in that
    # order), so an ORDER BY that is a prefix of the GROUP BY keys, each
    # ascending with NULLs first and the key's collation, needs no sort;
    # without GROUP BY there is one row.
    private def groups_give_order?(aggregation : Aggregation, sort_keys : Array(SortKey), extras : Array(Expr), width : Int32) : Bool
      keys = aggregation.list_of_group_keys
      return true if keys.empty?
      return false if sort_keys.size > keys.size
      sort_keys.each_with_index.all? do |sort_key, index|
        term = extras[sort_key.position - width]
        !sort_key.descending && sort_key.nulls_first && sort_key.collation == aggregation.list_of_key_collations[index] &&
          (term.same?(keys[index]) || same_column?(term, keys[index]))
      end
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
      entry.column_use.mark(index)
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

    # The shape countOfViewOptimization rewrites: `SELECT count(*) FROM
    # (a UNION ALL b ...)` alone, each SELECT without WHERE, LIMIT or
    # DISTINCT.
    private def count_of_view?(core : SQL::SelectClause, order_by : Array(SQL::OrderingTerm)) : Bool
      return false unless order_by.empty? && core.where.nil? && core.having.nil? && core.group_by.empty? && core.columns.size == 1
      column = core.columns[0]
      return false unless column.is_a?(SQL::ExpressionColumn)
      call = column.expression
      return false unless call.is_a?(SQL::FunctionCall) && call.name.value.compare("count", case_insensitive: true) == 0
      return false unless call.arguments.empty? && call.over.nil? && call.over_name.nil?
      from = core.from
      return false unless from && from.items.size == 1
      source = from.items[0].source
      return false unless source.is_a?(SQL::SubquerySource)
      query = source.query
      return false if query.cores.size < 2 || !query.operators.all?(&.union_all?) || query.limit
      query.cores.all? do |arm|
        !arm.is_a?(SQL::SelectClause) || (arm.where.nil? && !arm.distinct.distinct? && arm.group_by.empty?)
      end
    end

    # A COLLATE name; BINARY stands in for an unknown one, which is
    # reported only where code generation looks the collation up
    # (sqlite3GetCollSeq): see `note_collation_use`.
    protected def collation_named(name : String) : Collation
      Collation.named?(name) || Collation::Binary
    end

    protected def unknown_collation_name(name : String) : String?
      Collation.named?(name) ? nil : name
    end

    # The unknown collations the clause being compiled uses, in the order
    # its comparisons and aggregates are built; nil outside a clause.
    @list_of_collation_uses : Array(String)? = nil

    protected def note_collation_use(name : String?) : Nil
      return unless name
      @list_of_collation_uses.try(&.<<(name))
    end

    # Runs the block with a fresh list of collation uses; returns the list.
    private def collation_uses(& : ->) : Array(String)
      saved = @list_of_collation_uses
      uses = [] of String
      @list_of_collation_uses = uses
      begin
        yield
      ensure
        @list_of_collation_uses = saved
      end
      uses
    end

    # sqlite3Select builds the GROUP BY, ORDER BY and DISTINCT key
    # infos (every key looked up, so the last unknown one is reported)
    # before it codes WHERE, HAVING and the result set (where code
    # generation stops at the first unknown one); the first step that
    # meets one decides the message.
    private def record_collation_error(group_keys : Array(String?), sort_keys : Array(String?), distinct_keys : Array(String?),
                                       clauses : Array(Array(String))) : Nil
      name = group_keys.compact.last? || sort_keys.compact.last? || distinct_keys.compact.last?
      name ||= clauses.compact_map(&.first?).first?
      record_codegen_error("no such collation sequence: #{name}") if name
    end
  end
end
