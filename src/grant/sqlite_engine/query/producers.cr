module Grant::SQLiteEngine::Query
  # A compiled query that yields result rows one at a time.
  abstract class Producer
    abstract def open(frame : Frame) : Nil

    # The next row, or nil when there are no more.
    abstract def next_row(frame : Frame) : Array(Value)?

    # Tells the producer its caller reads each row before asking for the
    # next one and keeps none, so it may hand out one array refilled for
    # every row (C SQLite's result registers). By default rows are fresh.
    def lend_rows : Nil
    end

    # For the top-level ORDER BY: whether the row last returned sorted equal
    # to the one before it (nil when the output has no defined order).
    def tied_with_previous? : Bool?
      nil
    end
  end

  # One aggregate function call in a SELECT core.
  class AggregateCall
    getter kind : AggregateFunctions::Kind
    getter list_of_arguments : Array(Expr)
    getter? distinct : Bool
    getter filter : Expr?
    getter collation : Collation
    getter result_index : Int32

    def initialize(@kind : AggregateFunctions::Kind, @list_of_arguments : Array(Expr), @distinct : Bool, @filter : Expr?,
                   @collation : Collation, @result_index : Int32)
    end

    def min_or_max? : Bool
      @kind.min? || @kind.max?
    end
  end

  # GROUP BY, the aggregates, and HAVING of one SELECT core.
  class Aggregation
    getter list_of_group_keys : Array(Expr)
    getter list_of_key_collations : Array(Collation)
    getter list_of_calls : Array(AggregateCall)
    getter having : Expr?
    getter list_of_slots : Array(Int32)

    def initialize(@list_of_group_keys : Array(Expr), @list_of_key_collations : Array(Collation),
                   @list_of_calls : Array(AggregateCall), @having : Expr?, @list_of_slots : Array(Int32))
    end
  end

  # The accumulated state of one group: its key, its accumulators, and the
  # rows the bare columns read (the last row loaded).
  private class Group
    getter list_of_key_values : Array(Value)
    getter list_of_accumulators : Array(AggregateFunctions::Accumulator)
    getter list_of_distinct_sets : Array(Set(Array(EqualityKey))?)
    property list_of_rows : Array(Array(Value))
    property list_of_rowids : Array(Int64?)

    def initialize(@list_of_key_values : Array(Value), @list_of_accumulators : Array(AggregateFunctions::Accumulator),
                   @list_of_distinct_sets : Array(Set(Array(EqualityKey))?), slot_count : Int32)
      @list_of_rows = Array(Array(Value)).new(slot_count) { [] of Value }
      @list_of_rowids = Array(Int64?).new(slot_count, nil)
    end

    # Makes this finished group a new one with *key_values*, keeping its
    # arrays, accumulators and DISTINCT sets (emptied).
    def recycle(key_values : Array(Value)) : Nil
      ValueBuffer.refill(@list_of_key_values, key_values)
      @list_of_accumulators.each(&.reset)
      @list_of_distinct_sets.each { |set| set.try &.clear }
    end
  end

  # One SELECT core: FROM (a row source), WHERE, then either a projection
  # per row or GROUP BY and aggregates, then DISTINCT. Each row is the
  # result columns followed by *extra* values (ORDER BY keys) that a
  # SortProducer above reads and drops.
  class CoreProducer < Producer
    @groups = [] of Group
    @group_position = 0
    @seen : Set(Array(EqualityKey))? = nil

    # *streaming*: the source delivers rows with equal GROUP BY keys next
    # to each other in ascending key order, so each group is finished when
    # the key changes (C's sorter-free GROUP BY over an index or rowid
    # order) and an outer LIMIT stops the scan.
    def initialize(@source : RowSource, @where : Expr?, @list_of_columns : Array(Expr), @list_of_extras : Array(Expr),
                   @aggregation : Aggregation?, @distinct : Bool, @list_of_column_collations : Array(Collation),
                   @streaming : Bool = false)
    end

    @current : Group? = nil
    @source_done = false

    def open(frame : Frame) : Nil
      @seen = @distinct ? Set(Array(EqualityKey)).new : nil
      if aggregation = @aggregation
        if @streaming
          @source.open(frame)
          # A group left unfinished by the last execution (a LIMIT stopped
          # it) is kept for reuse with the shown ones.
          if unfinished = @current
            @list_of_spare_groups << unfinished
          end
          @current = nil
          @source_done = false
        else
          @groups = collect_groups(frame, aggregation)
          @group_position = 0
        end
      else
        @source.open(frame)
      end
    end

    def next_row(frame : Frame) : Array(Value)?
      if (aggregation = @aggregation) && @streaming
        return next_streaming_row(frame, aggregation)
      end
      if aggregation = @aggregation
        while @group_position < @groups.size
          group = @groups[@group_position]
          @group_position += 1
          restore(frame, group, aggregation)
          if having = aggregation.having
            next unless having.holds?(frame)
          end
          row = project(frame)
          return row if row
        end
        return
      end
      while @source.advance(frame)
        if where = @where
          next unless where.holds?(frame)
        end
        row = project(frame)
        return row if row
      end
      nil
    end

    @lending = false
    @lent_row = [] of Value

    def lend_rows : Nil
      @lending = true
    end

    # The result row, or nil when DISTINCT has seen it.
    private def project(frame : Frame) : Array(Value)?
      column_count = @list_of_columns.size
      width = column_count + @list_of_extras.size
      if @lending && @lent_row.size == width
        # The lent row keeps its width from row to row; its values are
        # replaced.
        row = @lent_row
        @list_of_columns.each_with_index { |column, position| row.unsafe_put(position, Expr.value_of(column, frame)) }
        if seen = @seen
          return unless seen.add?(distinct_key(row))
        end
        @list_of_extras.each_with_index { |extra, position| row.unsafe_put(column_count + position, Expr.value_of(extra, frame)) }
        return row
      end
      if @lending
        row = @lent_row
        row.clear
      else
        row = Array(Value).new(width)
      end
      @list_of_columns.each { |column| row << Expr.value_of(column, frame) }
      if seen = @seen
        return unless seen.add?(distinct_key(row))
      end
      @list_of_extras.each { |extra| row << Expr.value_of(extra, frame) }
      row
    end

    # The DISTINCT key of the result columns at the front of *row*.
    private def distinct_key(row : Array(Value)) : Array(EqualityKey)
      Array(EqualityKey).new(@list_of_columns.size) do |index|
        ValueSemantics.equality_key(row[index], @list_of_column_collations[index]? || Collation::Binary)
      end
    end

    private def next_streaming_row(frame : Frame, aggregation : Aggregation) : Array(Value)?
      slots = aggregation.list_of_slots
      loop do
        group = next_streaming_group(frame, aggregation)
        return unless group
        # The source reads outer rows from the frame (join keys), so the
        # frame gets its rows back after the group is shown.
        saved_rows = @saved_rows
        saved_rowids = @saved_rowids
        saved_pending = @saved_pending
        if saved_rows.size == slots.size
          slots.each_with_index do |slot, position|
            saved_rows.unsafe_put(position, frame.list_of_rows[slot])
            saved_rowids.unsafe_put(position, frame.list_of_rowids[slot])
            saved_pending.unsafe_put(position, frame.list_of_pending[slot])
          end
        else
          saved_rows.clear
          saved_rowids.clear
          saved_pending.clear
          slots.each do |slot|
            saved_rows << frame.list_of_rows[slot]
            saved_rowids << frame.list_of_rowids[slot]
            saved_pending << frame.list_of_pending[slot]
          end
        end
        restore(frame, group, aggregation)
        row = nil
        if (having = aggregation.having).nil? || having.holds?(frame)
          row = project(frame)
        end
        slots.each_with_index do |slot, position|
          frame.list_of_rows[slot] = saved_rows[position]
          frame.list_of_rowids[slot] = saved_rowids[position]
          frame.list_of_pending[slot] = saved_pending[position]
        end
        # Nothing holds the shown group's arrays now; the group after the
        # current one reuses them.
        @list_of_spare_groups << group
        return row if row
      end
    end

    # Reads rows until the GROUP BY key changes; returns the finished group
    # (the row with the new key already starts the next one), or nil when
    # the rows are used up.
    private def next_streaming_group(frame : Frame, aggregation : Aggregation) : Group?
      calls = aggregation.list_of_calls
      until @source_done
        unless @source.advance(frame)
          @source_done = true
          break
        end
        if where = @where
          next unless where.holds?(frame)
        end
        # Rows arrive in group order, so a row starts a new group when its
        # key compares unequal to the current group's (OP_Compare).
        scratch = @scratch_keys
        group_keys = aggregation.list_of_group_keys
        if scratch.size == group_keys.size
          group_keys.each_with_index { |key, position| scratch.unsafe_put(position, Expr.value_of(key, frame)) }
        else
          scratch.clear
          group_keys.each { |key| scratch << Expr.value_of(key, frame) }
        end
        current = @current
        if current && same_group_key?(scratch, current.list_of_key_values, aggregation.list_of_key_collations)
          step_group(frame, current, aggregation, first: false)
          next
        end
        group = recycled_group(scratch) || new_group(scratch.dup, calls, aggregation.list_of_slots.size)
        step_group(frame, group, aggregation, first: true)
        @current = group
        return current if current
      end
      finished = @current
      @current = nil
      finished
    end

    @scratch_keys = [] of Value
    @saved_rows = [] of Array(Value)
    @saved_rowids = [] of Int64?
    @saved_pending = [] of TableScanSource?
    # Finished groups whose arrays and accumulators the next groups reuse,
    # kept from one execution to the next.
    @list_of_spare_groups = [] of Group

    private def recycled_group(keys : Array(Value)) : Group?
      spare = @list_of_spare_groups.pop?
      return unless spare
      spare.recycle(keys)
      spare
    end

    @list_of_argument_buffers = [] of Array(Value)

    private def same_group_key?(keys : Array(Value), current : Array(Value), collations : Array(Collation)) : Bool
      keys.each_with_index do |value, index|
        return false unless ValueSemantics.compare(value, current.unsafe_fetch(index), collations.unsafe_fetch(index)) == 0
      end
      true
    end

    # One argument array per aggregate call, refilled for each row (no
    # accumulator keeps the array it is given).
    private def argument_buffer(index : Int32) : Array(Value)
      buffers = @list_of_argument_buffers
      while buffers.size <= index
        buffers << [] of Value
      end
      buffers.unsafe_fetch(index)
    end

    # Feeds the frame's row to *group*'s accumulators. updateAccumulator
    # loads the bare columns on a group's first row (*first*), and after
    # that on rows where the last min() or max() call took the row's value
    # (each OP_CollSeq resets the shared hit flag, so the last call
    # decides); with no min() or max() only the first row shows.
    private def step_group(frame : Frame, group : Group, aggregation : Aggregation, first : Bool) : Nil
      deciding_hit = false
      aggregation.list_of_calls.each_with_index do |call, index|
        deciding_hit = false if call.min_or_max?
        if filter = call.filter
          next unless filter.holds?(frame)
        end
        if call.kind.json?
          JsonAggregates.step(call, group.list_of_accumulators.unsafe_fetch(index), group.list_of_distinct_sets.unsafe_fetch(index), frame)
          next
        end
        list_of_arguments = call.list_of_arguments
        # One argument (or count's none) without DISTINCT needs no argument
        # array.
        if list_of_arguments.size <= 1 && group.list_of_distinct_sets.unsafe_fetch(index).nil?
          accumulator = group.list_of_accumulators.unsafe_fetch(index)
          accumulator.step_one(list_of_arguments.empty? ? nil : Expr.value_of(list_of_arguments.unsafe_fetch(0), frame))
          deciding_hit = accumulator.hit? if call.min_or_max?
          next
        end
        arguments = argument_buffer(index)
        # The buffer keeps its size from row to row; its values are replaced.
        if arguments.size == list_of_arguments.size
          list_of_arguments.each_with_index { |argument, position| arguments.unsafe_put(position, Expr.value_of(argument, frame)) }
        else
          arguments.clear
          list_of_arguments.each { |argument| arguments << Expr.value_of(argument, frame) }
        end
        if distinct_set = group.list_of_distinct_sets[index]
          next if arguments.any?(Nil) && !call.kind.count_rows?
          distinct_key = arguments.map { |argument| ValueSemantics.equality_key(argument, call.collation) }
          next unless distinct_set.add?(distinct_key)
        end
        accumulator = group.list_of_accumulators[index]
        accumulator.step(arguments)
        deciding_hit = accumulator.hit? if call.min_or_max?
      end
      if first || deciding_hit
        aggregation.list_of_slots.each_with_index do |slot, position|
          # Table sources refill one array per row, so the group keeps a copy.
          frame.complete_row(slot)
          ValueBuffer.refill(group.list_of_rows.unsafe_fetch(position), frame.list_of_rows[slot])
          group.list_of_rowids[position] = frame.list_of_rowids[slot]
        end
      end
    end

    private def collect_groups(frame : Frame, aggregation : Aggregation) : Array(Group)
      groups = {} of Array(EqualityKey) => Group
      list = [] of Group
      slots = aggregation.list_of_slots
      calls = aggregation.list_of_calls
      keys = aggregation.list_of_group_keys
      collations = aggregation.list_of_key_collations
      # Without GROUP BY every row joins the one group: no key to hash.
      only = nil.as(Group?)
      key_values = [] of Value
      hash_key = [] of EqualityKey
      @source.open(frame)
      while @source.advance(frame)
        if where = @where
          next unless where.holds?(frame)
        end
        if keys.empty?
          group = only
          first = group.nil?
          unless group
            group = only = new_group([] of Value, calls, slots.size)
            list << group
          end
          step_group(frame, group, aggregation, first)
          next
        end
        # The key arrays are reused for each row and copied only for a
        # new group.
        key_values.clear
        keys.each { |key| key_values << Expr.value_of(key, frame) }
        hash_key.clear
        key_values.each_with_index { |value, index| hash_key << ValueSemantics.equality_key(value, collations[index]) }
        group = groups[hash_key]?
        first = group.nil?
        unless group
          group = new_group(key_values.dup, calls, slots.size)
          groups[hash_key.dup] = group
          list << group
        end
        step_group(frame, group, aggregation, first)
      end
      if list.empty? && aggregation.list_of_group_keys.empty?
        list << new_group([] of Value, calls, slots.size)
      end
      unless aggregation.list_of_group_keys.empty?
        collations = aggregation.list_of_key_collations
        list = Sorting.stable_sort(list) do |left, right|
          Sorting.compare_keys(left.list_of_key_values, right.list_of_key_values, collations)
        end
      end
      list
    end

    private def new_group(key_values : Array(Value), calls : Array(AggregateCall), slot_count : Int32) : Group
      accumulators = calls.map { |call| AggregateFunctions::Accumulator.for(call.kind, call.collation) }
      distinct_sets = calls.map { |call| call.distinct? ? Set(Array(EqualityKey)).new : nil }
      Group.new(key_values, accumulators, distinct_sets, slot_count)
    end

    private def restore(frame : Frame, group : Group, aggregation : Aggregation) : Nil
      aggregation.list_of_slots.each_with_index do |slot, position|
        frame.list_of_rows[slot] = group.list_of_rows[position]
        frame.list_of_rowids[slot] = group.list_of_rowids[position]
        frame.list_of_pending[slot] = nil
      end
      aggregation.list_of_calls.each_with_index do |call, index|
        frame.list_of_aggregate_values[call.result_index] = group.list_of_accumulators[index].finish
      end
    end
  end

  # Sorting helpers shared by ORDER BY, GROUP BY and compound selects.
  module Sorting
    # A stable merge sort (Crystal's `sort` is not stable).
    def self.stable_sort(list : Array(T), &compare : T, T -> Int32) : Array(T) forall T
      return list if list.size < 2
      buffer = list.dup
      source = list.dup
      width = 1
      while width < source.size
        start = 0
        while start < source.size
          middle = Math.min(start + width, source.size)
          finish = Math.min(start + 2 * width, source.size)
          left = start
          right = middle
          index = start
          while left < middle && right < finish
            if compare.call(source[right], source[left]) < 0
              buffer[index] = source[right]
              right += 1
            else
              buffer[index] = source[left]
              left += 1
            end
            index += 1
          end
          while left < middle
            buffer[index] = source[left]
            left += 1
            index += 1
          end
          while right < finish
            buffer[index] = source[right]
            right += 1
            index += 1
          end
          start += 2 * width
        end
        source, buffer = buffer, source
        width *= 2
      end
      source
    end

    def self.compare_keys(left : Array(Value), right : Array(Value), collations : Array(Collation)) : Int32
      left.each_with_index do |value, index|
        comparison = ValueSemantics.compare(value, right[index], collations[index]? || Collation::Binary)
        return comparison if comparison != 0
      end
      0
    end
  end

  # One ORDER BY key: where it sits in the row, and how it sorts.
  record SortKey, position : Int32, collation : Collation, descending : Bool, nulls_first : Bool

  # `SELECT count(*) FROM table` (isSimpleCount, OP_Count): one row, the
  # number of entries in the table's b-tree.
  class TableCountProducer < Producer
    @done = false

    def initialize(@database : Database, @table : TableInfo)
    end

    def open(frame : Frame) : Nil
      @done = false
    end

    def next_row(frame : Frame) : Array(Value)?
      return if @done
      @done = true
      @table.check_readable
      [BTreeCount.entries(@database, count_root_page, frame.session)] of Value
    end

    # OP_Count reads the b-tree with the fewest columns (select.c, the
    # isSimpleCount branch of sqlite3Select): an index other than a partial
    # one holds one entry per row in fewer pages than the table.
    private def count_root_page : UInt32
      best = nil
      unless @table.without_rowid?
        @table.list_of_indexes.each do |layout|
          next if layout.partial?
          size = layout.key_count + layout.list_of_tail_positions.size
          best = {size, layout.entry.root_page} if best.nil? || size < best[0]
        end
      end
      best ? best[1] : @table.root_page
    end
  end

  # ORDER BY: reads every row of its input, sorts them stably by the keys,
  # and returns the first *width* values of each.
  class SortProducer < Producer
    @rows = [] of Array(Value)
    @collected = [] of Array(Value)
    @position = 0
    @tied = false

    # *presorted*: the input already comes in key order (the planner read
    # it in an order that gives it), so rows pass through as they arrive.
    def initialize(@input : Producer, @list_of_keys : Array(SortKey), @width : Int32, @presorted : Bool = false)
    end

    def open(frame : Frame) : Nil
      @input.open(frame)
      @has_previous = false
      return if @presorted
      # The list that collects the rows is kept for the next run; one row
      # (a lookup by key) is already in order.
      rows = @collected
      rows.clear
      while row = @input.next_row(frame)
        rows << row
      end
      @rows = rows.size > 1 ? Sorting.stable_sort(rows) { |left, right| compare(left, right) } : rows
      @position = 0
    end

    # Rows that pass through are copied aside and cut in place, never kept.
    def lend_rows : Nil
      @input.lend_rows if @presorted
    end

    def compare(left : Array(Value), right : Array(Value)) : Int32
      SortProducer.compare(@list_of_keys, left, right)
    end

    def self.compare(list_of_keys : Array(SortKey), left : Array(Value), right : Array(Value)) : Int32
      list_of_keys.each do |key|
        left_value = left[key.position]
        right_value = right[key.position]
        if left_value.nil? || right_value.nil?
          next if left_value.nil? && right_value.nil?
          return left_value.nil? == key.nulls_first ? -1 : 1
        end
        comparison = ValueSemantics.compare(left_value, right_value, key.collation)
        comparison = -comparison if key.descending
        return comparison if comparison != 0
      end
      0
    end

    def next_row(frame : Frame) : Array(Value)?
      if @presorted
        row = @input.next_row(frame)
        return unless row
      else
        return if @position >= @rows.size
        row = @rows[@position]
        @position += 1
      end
      @tied = @has_previous && compare(@previous_row, row) == 0
      # The row is this producer's own: its key columns are kept aside for
      # the next comparison and cut off in place.
      @previous_row.replace(row)
      @has_previous = true
      row.truncate(0, @width) if row.size > @width
      row
    end

    @previous_row = [] of Value
    @has_previous = false

    def tied_with_previous? : Bool?
      @tied
    end
  end

  # LIMIT and OFFSET (OP_MustBeInt: each must be an integer after NUMERIC
  # affinity, or the statement fails with "datatype mismatch"; a negative
  # LIMIT means no limit and a negative OFFSET none).
  class LimitProducer < Producer
    @remaining = -1_i64

    def initialize(@input : Producer, @limit : Expr, @offset : Expr?)
    end

    def self.integer_or_mismatch(value : Value) : Int64
      converted = ValueSemantics.apply_affinity(value, ExpressionAffinity::Numeric)
      return converted if converted.is_a?(Int64)
      raise SQLError.new("datatype mismatch", SQLError::MISMATCH)
    end

    def open(frame : Frame) : Nil
      @remaining = LimitProducer.integer_or_mismatch(@limit.evaluate(frame))
      # computeLimitRegisters: LIMIT 0 jumps past the whole query before
      # the OFFSET is read or a row is computed.
      return if @remaining == 0
      skip = 0_i64
      if offset = @offset
        skip = Math.max(LimitProducer.integer_or_mismatch(offset.evaluate(frame)), 0_i64)
      end
      @input.open(frame)
      while skip > 0
        break unless @input.next_row(frame)
        skip -= 1
      end
    end

    def lend_rows : Nil
      @input.lend_rows
    end

    def next_row(frame : Frame) : Array(Value)?
      return if @remaining == 0
      row = @input.next_row(frame)
      @remaining -= 1 if row && @remaining > 0
      row
    end

    def tied_with_previous? : Bool?
      @input.tied_with_previous?
    end
  end

  # `VALUES (...), (...)`.
  class ValuesProducer < Producer
    @position = 0

    def initialize(@list_of_rows : Array(Array(Expr)))
    end

    def open(frame : Frame) : Nil
      @position = 0
    end

    def next_row(frame : Frame) : Array(Value)?
      return if @position >= @list_of_rows.size
      row = @list_of_rows[@position].map(&.evaluate(frame))
      @position += 1
      row
    end
  end

  # UNION, UNION ALL, INTERSECT and EXCEPT of several cores, left to right.
  # Rows compare with each column's collation (multiSelectCollSeq).
  # Rows with OP_RealAffinity applied to the marked columns: an integer
  # becomes a real.
  class RealAffinityProducer < Producer
    def initialize(@input : Producer, @list_of_real_columns : Array(Bool))
    end

    def open(frame : Frame) : Nil
      @input.open(frame)
    end

    # Each row is copied as it is converted.
    def lend_rows : Nil
      @input.lend_rows
    end

    def next_row(frame : Frame) : Array(Value)?
      row = @input.next_row(frame)
      return unless row
      row.map_with_index do |value, index|
        @list_of_real_columns[index]? && value.is_a?(Int64) ? value.to_f64.as(Value) : value
      end
    end

    def tied_with_previous? : Bool?
      @input.tied_with_previous?
    end
  end

  # A compound SELECT. Without an ORDER BY, SQLite (multiSelect) writes each
  # UNION, INTERSECT or EXCEPT operand into an ephemeral index keyed by the
  # whole row: a row equal to one already there replaces it (the last
  # duplicate is the one kept), and the result comes out in index order.
  # With an ORDER BY (*ordered*), SQLite merges the sorted operands and keeps
  # the first of equal rows (multiSelectOrderBy), ordered by the ORDER BY
  # terms and then the remaining columns (*list_of_merge_keys*); the sort
  # that follows puts the rows in order.
  class CompoundProducer < Producer
    @rows = [] of Array(Value)
    @position = 0

    def initialize(@list_of_inputs : Array(Producer), @list_of_operators : Array(SQL::CompoundOperator),
                   @list_of_collations : Array(Collation), @ordered : Bool = false,
                   @list_of_merge_keys : Array(SortKey) = [] of SortKey)
    end

    def open(frame : Frame) : Nil
      result = read_all(@list_of_inputs[0], frame)
      indexed = false
      @list_of_operators.each_with_index do |operator, index|
        # OP_IfEmpty: an INTERSECT or EXCEPT whose left side is empty never
        # runs its right side.
        if result.empty? && (operator.intersect? || operator.except?)
          indexed = true
          next
        end
        right = read_all(@list_of_inputs[index + 1], frame)
        result = case operator
                 in .union_all? then result + right
                 in .union?     then distinct(result + right)
                 in .intersect?
                   keys = right.map { |row| key(row) }.to_set
                   distinct(result).select { |row| keys.includes?(key(row)) }
                 in .except?
                   keys = right.map { |row| key(row) }.to_set
                   distinct(result).reject { |row| keys.includes?(key(row)) }
                 end
        indexed = !operator.union_all?
        # multiSelectOrderBy: a merge for an operator other than UNION ALL
        # orders by the ORDER BY terms and then every other column.
        if @ordered && indexed && !@list_of_merge_keys.empty?
          result = Sorting.stable_sort(result) { |first, second| SortProducer.compare(@list_of_merge_keys, first, second) }
        end
      end
      result = Sorting.stable_sort(result) { |left, right| compare_rows(left, right) } if indexed && !@ordered
      @rows = result
      @position = 0
    end

    private def compare_rows(left : Array(Value), right : Array(Value)) : Int32
      left.each_with_index do |value, index|
        order = ValueSemantics.compare(value, right[index], @list_of_collations[index]? || Collation::Binary)
        return order unless order == 0
      end
      0
    end

    private def read_all(input : Producer, frame : Frame) : Array(Array(Value))
      rows = [] of Array(Value)
      input.open(frame)
      while row = input.next_row(frame)
        rows << row
      end
      rows
    end

    private def key(row : Array(Value)) : Array(EqualityKey)
      row.map_with_index { |value, index| ValueSemantics.equality_key(value, @list_of_collations[index]? || Collation::Binary) }
    end

    private def distinct(rows : Array(Array(Value))) : Array(Array(Value))
      if @ordered
        seen = Set(Array(EqualityKey)).new
        return rows.select { |row| seen.add?(key(row)) }
      end
      kept = {} of Array(EqualityKey) => Array(Value)
      rows.each { |row| kept[key(row)] = row }
      kept.values
    end

    def next_row(frame : Frame) : Array(Value)?
      return if @position >= @rows.size
      row = @rows[@position]
      @position += 1
      row
    end
  end

  # A recursive CTE (lang_with.html, "Recursive Common Table Expressions"):
  # the initial rows go into a queue; each row taken from the queue is
  # output and fed alone to the recursive step, whose rows join the queue.
  # With UNION a row already queued once is not queued again; an ORDER BY
  # makes the queue a priority queue; LIMIT stops the output.
  class RecursiveProducer < Producer
    @queue = Deque(Array(Value)).new
    @seen : Set(Array(EqualityKey))? = nil
    @remaining = -1_i64
    @skip = 0_i64
    @produced = 0_i64
    @stepped : Array(Value)? = nil

    def initialize(@initial : Producer, @recursive : Producer, @queue_row : QueueRowSource, @union_all : Bool,
                   @list_of_collations : Array(Collation), @list_of_order_keys : Array(SortKey), @limit : Expr?,
                   @offset : Expr?, @row_budget : Int64)
    end

    def open(frame : Frame) : Nil
      limit = -1_i64
      skip = 0_i64
      if limit_expression = @limit
        limit = LimitProducer.integer_or_mismatch(limit_expression.evaluate(frame))
      end
      if offset_expression = @offset
        skip = Math.max(LimitProducer.integer_or_mismatch(offset_expression.evaluate(frame)), 0_i64)
      end
      @seen = @union_all ? nil : Set(Array(EqualityKey)).new
      @queue = Deque(Array(Value)).new
      @produced = 0_i64
      @remaining = limit
      @skip = skip
      @stepped = nil
      @initial.open(frame)
      while row = @initial.next_row(frame)
        enqueue(row)
      end
    end

    private def enqueue(row : Array(Value)) : Nil
      if seen = @seen
        return unless seen.add?(row.map_with_index { |value, index| ValueSemantics.equality_key(value, @list_of_collations[index]? || Collation::Binary) })
      end
      insert(@queue, row)
    end

    # generateWithRecursiveQuery: a row taken from the queue is output, and
    # its recursive step runs when the next row is wanted.
    def next_row(frame : Frame) : Array(Value)?
      loop do
        if stepped = @stepped
          @stepped = nil
          @queue_row.current = stepped
          @recursive.open(frame)
          while next_row = @recursive.next_row(frame)
            enqueue(next_row)
          end
        end
        return if @queue.empty? || @remaining == 0
        row = @queue.shift
        @produced += 1
        raise SQLError.new("recursive query produced more than #{@row_budget} rows") if @produced > @row_budget
        @stepped = row
        if @skip > 0
          @skip -= 1
          next
        end
        @remaining -= 1 if @remaining > 0
        return row
      end
    end

    # Adds a row to the queue: at the end, or after every row that sorts
    # before or equal to it when the CTE has an ORDER BY.
    private def insert(queue : Deque(Array(Value)), row : Array(Value)) : Nil
      if @list_of_order_keys.empty?
        queue << row
        return
      end
      index = queue.size
      while index > 0 && compare(queue[index - 1], row) > 0
        index -= 1
      end
      queue.insert(index, row)
    end

    private def compare(left : Array(Value), right : Array(Value)) : Int32
      @list_of_order_keys.each do |key|
        left_value = left[key.position]?
        right_value = right[key.position]?
        if left_value.nil? || right_value.nil?
          next if left_value.nil? && right_value.nil?
          return left_value.nil? == key.nulls_first ? -1 : 1
        end
        comparison = ValueSemantics.compare(left_value, right_value, key.collation)
        comparison = -comparison if key.descending
        return comparison if comparison != 0
      end
      0
    end
  end
end
