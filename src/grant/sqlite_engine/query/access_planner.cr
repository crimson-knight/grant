module Grant::SQLiteEngine::Query
  # Expression helpers the planner uses to see what a term refers to.
  module ExpressionWalk
    # The direct operands of a compiled expression.
    def self.children(expression : Expr) : Array(Expr)
      expression.children
    end

    # Every frame slot *expression* reads, including the outer slots its
    # subqueries read.
    def self.slots(expression : Expr, into : Set(Int32) = Set(Int32).new) : Set(Int32)
      case expression
      when ColumnExpr then into << expression.slot
      when RowidExpr  then into << expression.slot
      when SubqueryExpr
        expression.list_of_outer_slots.each { |slot| into << slot }
        ExpressionWalk.children(expression).each { |child| slots(child, into) }
      else
        ExpressionWalk.children(expression).each { |child| slots(child, into) }
      end
      into
    end

    NONDETERMINISTIC = %w[random randomblob changes total_changes last_insert_rowid]

    # sqlite3ExprIsConstantNotJoin: a term that reads no row, no subquery,
    # no aggregate and no function whose value can change between calls.
    def self.constant_term?(expression : Expr) : Bool
      return false if expression.is_a?(ColumnExpr) || expression.is_a?(RowidExpr) || expression.is_a?(SubqueryExpr) ||
                      expression.is_a?(AggregateResultExpr) || expression.is_a?(UserFunctionExpr)
      return false if expression.is_a?(FunctionExpr) && NONDETERMINISTIC.includes?(expression.function_name)
      ExpressionWalk.children(expression).all? { |child| constant_term?(child) }
    end

    # sqlite3ExprImpliesNonNullRow (expr.c): true when *expression* cannot
    # be true while the row in *slot* is the NULL row a LEFT JOIN supplies.
    # At the top an AND needs one side to; inside, both sides of an AND or
    # OR must, and functions, CASE, IS and NULL tests stop the search.
    def self.implies_non_null_row?(expression : Expr, slot : Int32) : Bool
      while expression.is_a?(CollateExpr) || expression.is_a?(PassThroughExpr)
        expression = expression.children.first
      end
      if expression.is_a?(NullTestExpr) && expression.negated?
        return walk_non_null(expression.operand, slot)
      end
      while expression.is_a?(LogicalExpr) && expression.conjunction? && !expression.between?
        return true if implies_non_null_row?(expression.left, slot)
        expression = expression.right
      end
      walk_non_null(expression, slot)
    end

    private def self.walk_non_null(expression : Expr, slot : Int32) : Bool
      case expression
      when ColumnExpr then expression.slot == slot
      when RowidExpr  then expression.slot == slot
      when LogicalExpr
        if expression.between?
          low = expression.left.as?(ComparisonExpr)
          high = expression.right.as?(ComparisonExpr)
          return false unless low && high
          walk_non_null(low.left, slot) || (walk_non_null(low.right, slot) && walk_non_null(high.right, slot))
        else
          walk_non_null(expression.left, slot) && walk_non_null(expression.right, slot)
        end
      when ComparisonExpr
        return false if expression.operator.null_safe?
        walk_non_null(expression.left, slot) || walk_non_null(expression.right, slot)
      when InListExpr
        !expression.list.empty? && walk_non_null(expression.operand, slot)
      when NotExpr, ArithmeticExpr, BitwiseExpr, ConcatExpr, NegateExpr, BitNotExpr, CollateExpr, UnaryPlusExpr, CastExpr
        expression.children.any? { |child| walk_non_null(child, slot) }
      else
        false
      end
    end

    # The conjuncts of an AND tree.
    def self.conjuncts(expression : Expr?, into : Array(Expr) = [] of Expr) : Array(Expr)
      return into unless expression
      if expression.is_a?(LogicalExpr) && expression.conjunction?
        conjuncts(expression.left, into)
        conjuncts(expression.right, into)
      else
        into << expression
      end
      into
    end

    def self.conjunction(terms : Array(Expr)) : Expr?
      return if terms.empty?
      terms.reduce { |all, term| LogicalExpr.new(true, all, term).as(Expr) }
    end
  end

  class Compiler
    # Builds the join tree for a core's FROM entries: each entry read by
    # the best rowid or index path its WHERE or ON terms allow, WHERE terms
    # applied as soon as every entry they read has a row (but never inside
    # the right side of a LEFT JOIN, where NULL rows must reach them).
    # Returns the source and the WHERE terms left for after the joins.
    private def plan_access(steps : Array(JoinStep), where : Expr?, context : QueryContext) : {RowSource, Expr?}
      return {SingleRowSource.new.as(RowSource), where} if steps.empty?
      slot_position = {} of Int32 => Int32
      steps.each_with_index { |step, index| slot_position[step.entry.slot] = index }
      terms = ExpressionWalk.conjuncts(where)
      constant_terms, terms = terms.partition { |term| ExpressionWalk.constant_term?(term) }
      # sqlite3SimplifyJoin... (select.c, "LEFT JOIN simplification"): a
      # LEFT JOIN whose right table a WHERE term needs non-NULL runs as an
      # inner join, its ON terms joining the WHERE terms.
      outer = steps.map_with_index do |step, index|
        step.left_join? && index > 0 && terms.none? { |term| ExpressionWalk.implies_non_null_row?(term, step.entry.slot) }
      end
      pushed = Array(Array(Expr)).new(steps.size) { [] of Expr }
      residual = [] of Expr
      terms.each do |term|
        used = ExpressionWalk.slots(term).compact_map { |slot| slot_position[slot]? }
        owner = used.max? || 0
        if outer[owner] || term.is_a?(AggregateResultExpr)
          residual << term
        else
          pushed[owner] << term
        end
      end
      source = SingleRowSource.new.as(RowSource)
      steps.each_with_index do |step, index|
        available = steps[0, index].map(&.entry.slot).to_set
        if outer[index]
          access = choose_access(step, ExpressionWalk.conjuncts(step.on), available, context)
          source = JoinSource.new(source, access, step.on, true, [step.entry.slot])
          next
        end
        # The WHERE terms, then the ON terms (sqlite3ProcessJoin appends ON
        # to WHERE); the equalities an index or rowid seek would use first,
        # since SQLite consumes those in the seek.
        step_terms = pushed[index] + ExpressionWalk.conjuncts(step.on)
        access = choose_access(step, step_terms, available, context)
        seeks, others = step_terms.partition { |term| seek_term?(term, step.entry, available, context) }
        if filter = ExpressionWalk.conjunction(seeks + others)
          access = FilterSource.new(access, filter)
        end
        source = index == 0 ? access : JoinSource.new(source, access, nil, false, [step.entry.slot])
      end
      if gate = ExpressionWalk.conjunction(constant_terms)
        source = ConstantGateSource.new(source, gate)
      end
      {source, ExpressionWalk.conjunction(residual)}
    end

    # An equality between a column (or rowid) of *entry* and a value known
    # before *entry* is read.
    private def seek_term?(term : Expr, entry : FromEntry, available : Set(Int32), context : QueryContext) : Bool
      oriented = oriented(term, entry, available, context)
      return false unless oriented
      oriented[0].equal?
    end

    # True when *expression* can be evaluated before the entry in *slot*
    # has a row: it reads only earlier entries, outer queries, parameters
    # and constants.
    private def available?(expression : Expr, slot : Int32, available : Set(Int32), context : QueryContext) : Bool
      ExpressionWalk.slots(expression).all? do |used|
        used != slot && (available.includes?(used) || !context.owns_slot?(used))
      end
    end

    private def rowid_of?(expression : Expr, entry : FromEntry) : Bool
      expression.is_a?(RowidExpr) && expression.slot == entry.slot
    end

    private def column_of(expression : Expr, entry : FromEntry) : Int32?
      if expression.is_a?(ColumnExpr) && expression.slot == entry.slot
        return expression.column
      end
      if expression.is_a?(RowidExpr) && expression.slot == entry.slot
        return entry.table.try(&.rowid_alias)
      end
      nil
    end

    # A comparison term as `entry column OP other side`, or nil.
    private def oriented(term : Expr, entry : FromEntry, available : Set(Int32),
                         context : QueryContext) : {ComparisonOperator, Expr, Expr, ComparisonExpr}?
      return unless term.is_a?(ComparisonExpr)
      left = term.left
      right = term.right
      if (rowid_of?(left, entry) || column_of(left, entry)) && available?(right, entry.slot, available, context)
        return {term.operator, left, right, term}
      end
      if (rowid_of?(right, entry) || column_of(right, entry)) && available?(left, entry.slot, available, context)
        return {term.operator.commuted, right, left, term}
      end
      nil
    end

    private def choose_access(step : JoinStep, terms : Array(Expr), available : Set(Int32), context : QueryContext) : RowSource
      entry = step.entry
      table = entry.table
      return step.base_source if table.nil? || table.without_rowid?
      database = @session.database
      low = nil.as(Expr?)
      high = nil.as(Expr?)
      terms.each do |term|
        if term.is_a?(InListExpr) && !term.negated? && rowid_of?(term.operand, entry) &&
           term.list.all? { |value| available?(value, entry.slot, available, context) }
          return RowidLookupSource.new(database, table, entry.slot, term.list)
        end
        oriented = oriented(term, entry, available, context)
        next unless oriented
        operator, column, other, _comparison = oriented
        next unless rowid_of?(column, entry)
        case operator
        when .equal?
          return RowidLookupSource.new(database, table, entry.slot, [other])
        when .greater?, .greater_or_equal?
          low ||= other
        when .less?, .less_or_equal?
          high ||= other
        end
      end
      unless entry.not_indexed?
        if index_access = choose_index(step, table, terms, available, context)
          return index_access
        end
      end
      if low || high
        return RowidRangeSource.new(database, table, entry.slot, low, high)
      end
      step.base_source
    end

    # The index whose leading key columns the most equality terms fix.
    private def choose_index(step : JoinStep, table : TableInfo, terms : Array(Expr), available : Set(Int32),
                             context : QueryContext) : RowSource?
      entry = step.entry
      best = nil
      best_score = 0
      table.list_of_indexes.each do |layout|
        next if layout.unsupported_reason
        if hint = entry.indexed_by
          next unless layout.entry.object_name.compare(hint, case_insensitive: true) == 0
        end
        key_columns = layout.comparator.list_of_key_columns
        equal = [] of {Expr, ExpressionAffinity}
        range_low = nil
        range_high = nil
        layout.list_of_key_positions.each_with_index do |position, key_index|
          key = key_columns[key_index]
          found = find_index_term(terms, entry, position, key, table, available, context, equality: true)
          if found
            equal << found
            next
          end
          unless key.descending
            range_low = find_index_term(terms, entry, position, key, table, available, context, equality: false, lower: true)
            range_high = find_index_term(terms, entry, position, key, table, available, context, equality: false, lower: false)
          end
          break
        end
        score = equal.size * 4 + (range_low ? 1 : 0) + (range_high ? 1 : 0)
        score += 2 if layout.unique? && equal.size == layout.key_count
        if score > best_score
          best_score = score
          order = IndexOrder.new(key_columns.map(&.collation), key_columns.map(&.descending))
          best = IndexLookupSource.new(@session.database, table, entry.slot, order, layout.entry.root_page, equal,
            range_low, range_high)
        end
      end
      best
    end

    # A term comparing the key column at table column *position* with a
    # value available before this entry, usable with the index: same
    # collation, and an affinity indexAffinityOk accepts. Returns the value
    # and the affinity to convert it with before seeking.
    private def find_index_term(terms : Array(Expr), entry : FromEntry, position : Int32, key : KeyColumn, table : TableInfo,
                                available : Set(Int32), context : QueryContext, equality : Bool,
                                lower : Bool = true) : {Expr, ExpressionAffinity}?
      column_affinity = table.list_of_affinities[position]
      terms.each do |term|
        oriented = oriented(term, entry, available, context)
        next unless oriented
        operator, column, other, comparison = oriented
        next unless column_of(column, entry) == position
        if equality
          next unless operator.equal?
        elsif lower
          next unless operator.greater? || operator.greater_or_equal?
        else
          next unless operator.less? || operator.less_or_equal?
        end
        next unless comparison.collation == key.collation
        affinity = comparison.comparison_affinity
        usable = if affinity < ExpressionAffinity::Text
                   true
                 elsif affinity.text?
                   column_affinity.text?
                 else
                   column_affinity.numeric?
                 end
        next unless usable
        conversion = affinity < ExpressionAffinity::Text ? ExpressionAffinity::None : column_affinity
        return {other, conversion}
      end
      nil
    end
  end
end
