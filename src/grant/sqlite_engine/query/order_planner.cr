module Grant::SQLiteEngine::Query
  # One term of the order a query wants its rows in: an ORDER BY term, or
  # a GROUP BY key (ascending, NULLs first).
  record OrderTerm, expression : Expr, collation : Collation, descending : Bool, nulls_first : Bool

  # One column of the order a row source delivers: the column (nil for
  # the rowid) of the entry in *slot*, its collation and direction.
  # *unique*: no two rows share it, so later terms on the same entry are
  # decided by it.
  record OrderElement, slot : Int32, column : Int32?, collation : Collation, descending : Bool, unique : Bool

  # A way to read one FROM entry, with the planner's estimate of its cost
  # (whereLoopAddBtree's rRun, in rows read, with SQLite's default row
  # estimates since no sqlite_stat1 is read) and the order its rows come
  # in. *fixed* lists columns an equality pins to one value.
  record AccessChoice, source : RowSource, cost : Float64, rows : Float64, order : Array(OrderElement),
    fixed : Array(Int32)

  class Compiler
    # SQLite assumes a table of about a million rows when it has no
    # statistics (sqlite3DefaultRowEst: nRowLogEst 200, about 2^20).
    DEFAULT_TABLE_ROWS = 1_048_576.0
    # Rows an equality on an index's first column leaves (aiRowLogEst[1],
    # LogEst 33).
    DEFAULT_EQUALITY_ROWS = 10.0

    # wherePathSolver weighs reading in index order against sorting: with
    # *ordering* wanted, the first FROM entry is read the cheapest way
    # counting the sort (whereSortingCost, about n log n) a path needs when
    # its order does not give the wanted order. Returns the choice and
    # whether its order gives *ordering*.
    private def choose_ordered_access(step : JoinStep, terms : Array(Expr), context : QueryContext,
                                      ordering : Array(OrderTerm), limit_rows : Float64? = nil) : {AccessChoice, Bool}
      available = Set(Int32).new
      filtering = choose_access(step, terms, available, context)
      return {filtering, false} if ordering.empty?
      best = filtering
      best_ordered = order_satisfied?(ordering, filtering, step.entry)
      # The share of rows the WHERE terms keep: what the best filtering
      # path expects to read, or a quarter per term, whichever is less.
      selectivity = Math.min(0.25 ** terms.size, filtering.rows / DEFAULT_TABLE_ROWS)
      best_cost = ordered_cost(filtering, best_ordered, selectivity, limit_rows)
      list_of_ordered_choices(step, context).each do |choice|
        next unless order_satisfied?(ordering, choice, step.entry)
        cost = ordered_cost(choice, true, selectivity, limit_rows)
        if cost < best_cost
          best = choice
          best_ordered = true
          best_cost = cost
        end
      end
      {best, best_ordered}
    end

    # The cost of reading through *choice* and then sorting unless
    # *ordered*. Rows that come in order stop at the LIMIT: about
    # limit / selectivity rows are read. Unordered rows all pass through a
    # sort that keeps the LIMIT's best rows.
    private def ordered_cost(choice : AccessChoice, ordered : Bool, selectivity : Float64, limit_rows : Float64?) : Float64
      unless ordered
        kept = limit_rows ? Math.min(limit_rows, choice.rows) : choice.rows
        return choice.cost + choice.rows * Math.max(Math.log2(Math.max(kept, 2.0)), 1.0)
      end
      return choice.cost unless limit_rows
      per_row = choice.cost / Math.max(choice.rows, 1.0)
      needed = Math.min(choice.rows, Math.max(limit_rows, 1.0) / selectivity)
      Math.min(choice.cost, needed * per_row)
    end

    # Full reads of the entry in an order: rowid order, and each index's
    # key order.
    private def list_of_ordered_choices(step : JoinStep, context : QueryContext) : Array(AccessChoice)
      entry = step.entry
      table = entry.table
      choices = [] of AccessChoice
      return choices if table.nil? || table.without_rowid?
      unless entry.indexed_by
        choices << AccessChoice.new(step.base_source, 3.0 * DEFAULT_TABLE_ROWS, DEFAULT_TABLE_ROWS,
          [OrderElement.new(entry.slot, nil, Collation::Binary, false, true)], [] of Int32)
      end
      return choices if entry.not_indexed?
      table.list_of_indexes.each do |layout|
        next if layout.unsupported_reason
        if hint = entry.indexed_by
          next unless layout.entry.object_name.compare(hint, case_insensitive: true) == 0
        end
        choices << index_choice(entry, table, layout, [] of {Expr, ExpressionAffinity}, nil, nil)
      end
      choices
    end

    # The choice for reading *table* through *layout* with *equal* values
    # on its first key columns and optional bounds on the next.
    private def index_choice(entry : FromEntry, table : TableInfo, layout : IndexLayout,
                             equal : Array({Expr, ExpressionAffinity}), low : {Expr, ExpressionAffinity, Bool}?,
                             high : {Expr, ExpressionAffinity, Bool}?) : AccessChoice
      key_columns = layout.comparator.list_of_key_columns
      order = IndexOrder.new(key_columns.map(&.collation), key_columns.map(&.descending))
      covering = covering?(entry, table, layout)
      source = IndexLookupSource.new(@session.database, table, entry.slot, order, layout.entry.root_page, equal,
        low, high, entry.column_use, covering ? layout.list_of_key_positions : nil)
      rows = if equal.empty?
               DEFAULT_TABLE_ROWS
             elsif layout.unique? && equal.size == layout.key_count
               1.0
             else
               Math.max(DEFAULT_EQUALITY_ROWS * (0.9 ** (equal.size - 1)), 1.0)
             end
      # whereRangeScanEst without STAT4: each bound keeps a quarter, and a
      # second bound a quarter again.
      rows /= 4.0 if low
      rows /= 4.0 if high
      rows /= 4.0 if low && high
      rows = Math.max(rows, 1.0)
      per_row = covering ? 1.5 : 4.0
      positions = layout.list_of_key_positions
      elements = [] of OrderElement
      positions.each_with_index do |position, key_index|
        next if key_index < equal.size
        elements << OrderElement.new(entry.slot, position, key_columns[key_index].collation, key_columns[key_index].descending, false)
      end
      elements << OrderElement.new(entry.slot, nil, Collation::Binary, false, true)
      fixed = positions[0, equal.size]
      AccessChoice.new(source, rows * per_row + Math.log2(DEFAULT_TABLE_ROWS), rows, elements, fixed)
    end

    # True when every column the query reads from *entry* is a key column
    # of *layout* or the rowid, so its rows can be built from index entries.
    private def covering?(entry : FromEntry, table : TableInfo, layout : IndexLayout) : Bool
      use = entry.column_use
      return false if use.all?
      positions = layout.list_of_key_positions
      alias_index = table.rowid_alias
      (0...table.list_of_column_names.size).all? do |column|
        !use.includes?(column) || column == alias_index || positions.includes?(column)
      end
    end

    # wherePathSatisfiesOrderBy, for the first FROM entry: the terms of
    # *ordering* follow the order *choice* delivers, skipping columns an
    # equality pins; once a unique column is matched, terms that read only
    # this entry (or nothing) are decided.
    private def order_satisfied?(ordering : Array(OrderTerm), choice : AccessChoice, entry : FromEntry) : Bool
      slot = entry.slot
      position = 0
      decided = false
      order = choice.order
      ordering.each do |term|
        expression = term.expression
        while expression.is_a?(CollateExpr)
          expression = expression.operand
        end
        if decided
          next if ExpressionWalk.constant_term?(term.expression)
          used = ExpressionWalk.slots(term.expression)
          next if used.all? { |used_slot| used_slot == slot }
          return false
        end
        column = ordering_column(expression, entry)
        if column && (fixed = column[0]) && choice.fixed.includes?(fixed)
          next
        end
        element = order[position]?
        return false unless element && column
        return false unless element.column.nil? ? column[1] : element.column == column[0]
        return false unless element.column.nil? || element.collation == term.collation
        return false unless element.descending == term.descending && term.nulls_first == !term.descending
        position += 1
        decided = element.unique
      end
      true
    end

    # The column (nil for the rowid) a term names on the entry in *slot*,
    # and whether it is the rowid; nil when it names something else.
    private def ordering_column(expression : Expr, entry : FromEntry) : {Int32?, Bool}?
      if expression.is_a?(RowidExpr) && expression.slot == entry.slot
        return {nil, true}
      end
      return unless expression.is_a?(ColumnExpr) && expression.slot == entry.slot
      alias_index = entry.table.try(&.rowid_alias)
      alias_index == expression.column ? {nil, true} : {expression.column, false}
    end
  end
end
