module Grant::SQLiteEngine::Query
  # Where a SELECT's rows come from: the FROM clause compiled to a tree of
  # sources pulled one row at a time. A source that moves puts its row in
  # its frame slot (`Frame#list_of_rows`) and its rowid beside it.
  abstract class RowSource
    # Starts (or restarts) the source for the current outer row.
    abstract def open(frame : Frame) : Nil

    # Moves to the next row; false when there are no more.
    abstract def advance(frame : Frame) : Bool
  end

  # One row with no columns: a SELECT without FROM.
  class SingleRowSource < RowSource
    @done = false

    def open(frame : Frame) : Nil
      @done = false
    end

    def advance(frame : Frame) : Bool
      return false if @done
      @done = true
    end
  end

  # Every row of a table, in rowid (or primary key) order.
  class TableScanSource < RowSource
    @table_cursor : TableCursor? = nil
    @key_cursor : IndexCursor? = nil
    @started = false

    def initialize(@database : Database, @table : TableInfo, @slot : Int32)
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      if @table.without_rowid?
        @key_cursor = IndexCursor.new(@database, @table.root_page, IndexOrder.new([] of Collation, [] of Bool))
      else
        @table_cursor = TableCursor.new(@database, @table.root_page)
      end
      @started = false
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      if cursor = @table_cursor
        moved = @started ? cursor.advance : cursor.first
        @started = true
        return false unless moved
        rowid = cursor.rowid
        frame.list_of_rows[@slot] = @table.row_from(rowid, cursor.record)
        frame.list_of_rowids[@slot] = rowid
        return true
      end
      cursor = @key_cursor
      return false unless cursor
      moved = @started ? cursor.advance : cursor.first
      @started = true
      return false unless moved
      frame.list_of_rows[@slot] = @table.row_from(nil, cursor.record)
      frame.list_of_rowids[@slot] = nil
      true
    end
  end

  # The rows of a rowid table whose rowid equals one of some values: `rowid
  # = x`, `rowid IN (...)` (OP_SeekRowid: a value that is not an integer
  # after NUMERIC affinity matches nothing).
  class RowidLookupSource < RowSource
    @keys = [] of Int64
    @position = 0
    @cursor : TableCursor? = nil

    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @key_expressions : Array(Expr))
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      keys = Set(Int64).new
      @key_expressions.each do |expression|
        key = ValueSemantics.apply_affinity(expression.evaluate(frame), ExpressionAffinity::Numeric)
        keys << key if key.is_a?(Int64)
      end
      @keys = keys.to_a.sort!
      @position = 0
      @cursor = TableCursor.new(@database, @table.root_page)
    end

    def advance(frame : Frame) : Bool
      cursor = @cursor
      return false unless cursor
      while @position < @keys.size
        key = @keys[@position]
        @position += 1
        next unless cursor.seek(key) && cursor.rowid == key
        frame.list_of_rows[@slot] = @table.row_from(key, cursor.record)
        frame.list_of_rowids[@slot] = key
        return true
      end
      false
    end
  end

  # The rows of a rowid table within rowid bounds. The bounds only narrow
  # the scan; the WHERE clause is still checked on every row.
  class RowidRangeSource < RowSource
    @cursor : TableCursor? = nil
    @started = false
    @high : Int64? = nil
    @empty = false

    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @low : Expr?, @high_expression : Expr?)
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      @cursor = TableCursor.new(@database, @table.root_page)
      @started = false
      @empty = false
      @start = Int64::MIN
      @high = nil
      if low = @low
        value = ValueSemantics.apply_affinity(low.evaluate(frame), ExpressionAffinity::Numeric)
        case value
        when Nil     then @empty = true
        when Int64   then @start = value
        when Float64 then @start = value <= -9.2233720368547758e18 ? Int64::MIN : (value >= 9.2233720368547758e18 ? Int64::MAX : value.floor.to_i64)
        end
      end
      if high = @high_expression
        value = ValueSemantics.apply_affinity(high.evaluate(frame), ExpressionAffinity::Numeric)
        case value
        when Nil     then @empty = true
        when Int64   then @high = value
        when Float64 then @high = value >= 9.2233720368547758e18 ? Int64::MAX : (value <= -9.2233720368547758e18 ? Int64::MIN : value.ceil.to_i64)
        end
      end
    end

    @start = Int64::MIN

    def advance(frame : Frame) : Bool
      frame.session.tick
      return false if @empty
      cursor = @cursor
      return false unless cursor
      moved = @started ? cursor.advance : cursor.seek(@start)
      @started = true
      return false unless moved
      rowid = cursor.rowid
      if (high = @high) && rowid > high
        @empty = true
        return false
      end
      frame.list_of_rows[@slot] = @table.row_from(rowid, cursor.record)
      frame.list_of_rowids[@slot] = rowid
      true
    end
  end

  # The rows of a rowid table found through an index: equal values on the
  # first key columns, optionally bounded on the next. Values are converted
  # with the comparison's affinity before the seek, as SQLite does; the
  # WHERE clause is still checked on every row.
  class IndexLookupSource < RowSource
    @index_cursor : IndexCursor? = nil
    @table_cursor : TableCursor? = nil
    @probe = [] of Value
    @high : Value = nil
    @has_high = false
    @started = false
    @empty = false

    # *equal* holds the value and the affinity to convert it with, per key
    # column; *low* and *high* bound the key column after them.
    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @order : IndexOrder, @root_page : UInt32,
                   @equal : Array({Expr, ExpressionAffinity}), @low : {Expr, ExpressionAffinity}?,
                   @high_bound : {Expr, ExpressionAffinity}?)
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      @started = false
      @empty = false
      @probe = @equal.map do |expression, affinity|
        converted = ValueSemantics.apply_record_affinity(expression.evaluate(frame), affinity)
        @empty = true if converted.nil?
        converted
      end
      @seek_key = @probe
      if low = @low
        value = ValueSemantics.apply_record_affinity(low[0].evaluate(frame), low[1])
        if value.nil?
          @empty = true
        else
          @seek_key = @probe + [value]
        end
      end
      @has_high = false
      if high = @high_bound
        value = ValueSemantics.apply_record_affinity(high[0].evaluate(frame), high[1])
        if value.nil?
          @empty = true
        else
          @high = value
          @has_high = true
        end
      end
      @index_cursor = IndexCursor.new(@database, @root_page, @order)
      @table_cursor = TableCursor.new(@database, @table.root_page)
    end

    @seek_key = [] of Value

    def advance(frame : Frame) : Bool
      frame.session.tick
      return false if @empty
      index_cursor = @index_cursor
      table_cursor = @table_cursor
      return false unless index_cursor && table_cursor
      loop do
        moved = @started ? index_cursor.advance : (@seek_key.empty? ? index_cursor.first : index_cursor.seek(@seek_key))
        @started = true
        return false unless moved
        entry = index_cursor.record
        unless @probe.empty? || @order.compare(entry, @probe) == 0
          @empty = true
          return false
        end
        if @has_high
          position = @probe.size
          collation = @order.collations[position]? || Collation::Binary
          if ValueSemantics.compare(entry[position]?, @high, collation) > 0
            @empty = true
            return false
          end
        end
        rowid = entry.last?
        next unless rowid.is_a?(Int64)
        next unless table_cursor.seek(rowid) && table_cursor.rowid == rowid
        frame.list_of_rows[@slot] = @table.row_from(rowid, table_cursor.record)
        frame.list_of_rowids[@slot] = rowid
        return true
      end
    end
  end

  # Rows computed by a query (a subquery or view in FROM, a CTE, VALUES,
  # a table-valued function), kept for the execution unless the query
  # refers to an outer row.
  class MaterializedSource < RowSource
    @rows : Array(Array(Value))? = nil
    @computed_for : Frame? = nil
    @position = 0

    def initialize(@slot : Int32, @producer : Producer, @correlated : Bool)
    end

    def open(frame : Frame) : Nil
      if @correlated || !@computed_for.same?(frame) || @rows.nil?
        rows = [] of Array(Value)
        @producer.open(frame)
        while row = @producer.next_row(frame)
          rows << row
        end
        @rows = rows
        @computed_for = frame
      end
      @position = 0
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      rows = @rows
      return false unless rows && @position < rows.size
      frame.list_of_rows[@slot] = rows[@position]
      frame.list_of_rowids[@slot] = nil
      @position += 1
      true
    end
  end

  # The one row a recursive CTE's recursive step sees: the row just taken
  # from the queue.
  class QueueRowSource < RowSource
    property current : Array(Value)? = nil
    @done = false

    def initialize(@slot : Int32)
    end

    def open(frame : Frame) : Nil
      @done = false
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      row = @current
      return false if @done || row.nil?
      @done = true
      frame.list_of_rows[@slot] = row
      frame.list_of_rowids[@slot] = nil
      true
    end
  end

  # Rows of a source that satisfy a condition.
  class FilterSource < RowSource
    def initialize(@source : RowSource, @condition : Expr)
    end

    def open(frame : Frame) : Nil
      @source.open(frame)
    end

    def advance(frame : Frame) : Bool
      while @source.advance(frame)
        return true if @condition.holds?(frame)
      end
      false
    end
  end

  # The WHERE terms that read no row, checked once before the first row is
  # read (sqlite3WhereBegin codes constant terms ahead of the loops): when
  # they do not hold, the source is empty.
  class ConstantGateSource < RowSource
    @open = false

    def initialize(@source : RowSource, @condition : Expr)
    end

    def open(frame : Frame) : Nil
      @open = @condition.holds?(frame)
      @source.open(frame) if @open
    end

    def advance(frame : Frame) : Bool
      @open && @source.advance(frame)
    end
  end

  # A nested-loop join. For each left row the right source restarts; a
  # LEFT join emits the left row once with NULL right columns when no right
  # row satisfied the ON condition.
  class JoinSource < RowSource
    @left_ready = false
    @matched = false

    def initialize(@left : RowSource, @right : RowSource, @condition : Expr?, @left_join : Bool,
                   @right_slots : Array(Int32))
    end

    def open(frame : Frame) : Nil
      @left.open(frame)
      @left_ready = false
    end

    def advance(frame : Frame) : Bool
      loop do
        unless @left_ready
          return false unless @left.advance(frame)
          @right.open(frame)
          @left_ready = true
          @matched = false
        end
        while @right.advance(frame)
          condition = @condition
          if condition.nil? || condition.holds?(frame)
            @matched = true
            return true
          end
        end
        @left_ready = false
        if @left_join && !@matched
          @right_slots.each do |slot|
            frame.list_of_rows[slot] = NULL_ROW
            frame.list_of_rowids[slot] = nil
          end
          return true
        end
      end
    end

    # A row with no columns reads NULL for every column.
    NULL_ROW = [] of Value
  end
end
