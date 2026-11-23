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

    # The row array this source fills for each row it moves to.
    @buffer = [] of Value

    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @use : ColumnUse = ColumnUse.new.tap(&.mark_all))
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      if @table.without_rowid?
        @key_cursor = IndexCursor.new(@database, @table.root_page, IndexOrder.new([] of Collation, [] of Bool))
      else
        @table_cursor ||= TableCursor.new(@database, @table.root_page)
      end
      @started = false
    end

    # WHERE terms on this table's rows, tested as each row is read: each
    # term's columns are decoded just before it is tested, so a row a term
    # rejects never has its other columns decoded (OP_Column reads a
    # column when it is needed). Each term comes with the columns it
    # reads, nil when it reads the whole row.
    @list_of_terms = [] of {Expr, Set(Int32)?}
    @list_of_term_positions = [] of Array(Int32)
    @rest_positions = [] of Int32
    # Per term, the test that decides it from the stored record when the
    # stored value allows (`ScanTest`), so a row a term rejects is often
    # rejected before any of its values is decoded.
    @list_of_tests = [] of ScanTest?
    # Terms of the current row a test passed without decoding their
    # columns; those columns are decoded before a later term or the query
    # reads them.
    @list_of_undecoded = [] of Int32
    @masks_ready = false
    @header = RecordHeader.new

    def filter_by(list_of_terms : Array({Expr, Set(Int32)?})) : Nil
      @list_of_terms = list_of_terms
      @masks_ready = false
    end

    def filtering? : Bool
      !@list_of_terms.empty?
    end

    # Splits the stored columns the query reads among the terms, each
    # term taking the columns no earlier term decoded.
    private def prepare_masks : Nil
      wanted = @use.stored_mask(@table)
      decoded = Array(Bool).new(wanted.size, false)
      @list_of_term_positions = @list_of_terms.map do |(_, columns)|
        needed = @table.stored_mask_for(columns)
        positions = (0...wanted.size).select { |position| needed[position] && !decoded[position] }
        positions.each { |position| decoded[position] = true }
        positions
      end
      @rest_positions = (0...wanted.size).select { |position| wanted[position] && !decoded[position] }
      encoding = @database.text_encoding
      @list_of_tests = @list_of_terms.map { |(term, _)| ScanTest.for(term, @slot, @table, encoding) }
      @masks_ready = true
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      if cursor = @table_cursor
        return advance_filtered(frame, cursor) unless @list_of_terms.empty?
        moved = @started ? cursor.advance : cursor.first
        @started = true
        return false unless moved
        frame.list_of_rowids[@slot] = cursor.row(@table, @use, @buffer)
        frame.list_of_rows[@slot] = @buffer
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

    private def advance_filtered(frame : Frame, cursor : TableCursor) : Bool
      prepare_masks unless @masks_ready
      encoding = @database.text_encoding
      undecoded = @list_of_undecoded
      loop do
        moved = @started ? cursor.advance : cursor.first
        @started = true
        return false unless moved
        rowid = cursor.header(@header)
        # Every column a term or the query reads is written before it is
        # read, so the buffer needs clearing only when its size is wrong.
        @table.clear_row(@buffer) unless @buffer.size == @table.list_of_column_names.size
        frame.list_of_rowids[@slot] = rowid
        frame.list_of_rows[@slot] = @buffer
        undecoded.clear unless undecoded.empty?
        if passes_terms?(frame, rowid, encoding, undecoded)
          undecoded.each { |index| fill_term_columns(index, rowid, encoding) }
          @table.fill_columns(@header, rowid, @rest_positions, encoding, @buffer)
          return true
        end
        frame.session.tick
      end
    end

    # Tests the current row against every term in order, as C codes them.
    private def passes_terms?(frame : Frame, rowid : Int64, encoding : TextEncoding, undecoded : Array(Int32)) : Bool
      @list_of_terms.each_with_index do |(term, _), index|
        if test = @list_of_tests.unsafe_fetch(index)
          verdict = test.verdict(@header, frame)
          return false if verdict == false
          if verdict
            undecoded << index
            next
          end
        end
        unless undecoded.empty?
          undecoded.each { |earlier| fill_term_columns(earlier, rowid, encoding) }
          undecoded.clear
        end
        fill_term_columns(index, rowid, encoding)
        return false unless term.holds?(frame)
      end
      true
    end

    private def fill_term_columns(index : Int32, rowid : Int64, encoding : TextEncoding) : Nil
      @table.fill_columns(@header, rowid, @list_of_term_positions.unsafe_fetch(index), encoding, @buffer)
    end
  end

  # The rows of a rowid table whose rowid equals one of some values: `rowid
  # = x`, `rowid IN (...)` (OP_SeekRowid: a value that is not an integer
  # after NUMERIC affinity matches nothing).
  class RowidLookupSource < RowSource
    @keys = [] of Int64
    @position = 0
    @cursor : TableCursor? = nil
    @buffer = [] of Value

    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @key_expressions : Array(Expr),
                   @use : ColumnUse = ColumnUse.new.tap(&.mark_all))
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
      @cursor ||= TableCursor.new(@database, @table.root_page)
    end

    def advance(frame : Frame) : Bool
      cursor = @cursor
      return false unless cursor
      while @position < @keys.size
        key = @keys[@position]
        @position += 1
        next unless cursor.seek(key) && cursor.rowid == key
        cursor.row(@table, @use, @buffer)
        frame.list_of_rows[@slot] = @buffer
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
    @buffer = [] of Value

    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @low : Expr?, @high_expression : Expr?,
                   @use : ColumnUse = ColumnUse.new.tap(&.mark_all))
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      @cursor ||= TableCursor.new(@database, @table.root_page)
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
      cursor.row(@table, @use, @buffer)
      frame.list_of_rows[@slot] = @buffer
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
    @buffer = [] of Value
    @probe = [] of Value
    @high : Value = nil
    @has_high = false
    # A `>` or `<` bound: entries equal to it are skipped, as the WHERE
    # term (still checked) would reject them.
    @strict_low = false
    @strict_high = false
    @started = false
    @empty = false

    # *equal* holds the value and the affinity to convert it with, per key
    # column; *low* and *high* bound the key column after them.
    def initialize(@database : Database, @table : TableInfo, @slot : Int32, @order : IndexOrder, @root_page : UInt32,
                   @equal : Array({Expr, ExpressionAffinity}), @low : {Expr, ExpressionAffinity, Bool}?,
                   @high_bound : {Expr, ExpressionAffinity, Bool}?, @use : ColumnUse = ColumnUse.new.tap(&.mark_all),
                   @covering : Array(Int32)? = nil)
    end

    def open(frame : Frame) : Nil
      @table.check_readable
      @started = false
      @empty = false
      # The probe, seek key and cursors are kept from one open to the next
      # (an inner join opens this source once per outer row).
      probe = @probe
      probe.clear
      @equal.each do |expression, affinity|
        converted = ValueSemantics.apply_record_affinity(expression.evaluate(frame), affinity)
        @empty = true if converted.nil?
        probe << converted
      end
      @strict_low = false
      seek_key = @seek_key
      seek_key.clear
      seek_key.concat(probe)
      if low = @low
        raw = low[0].evaluate(frame)
        value = ValueSemantics.apply_record_affinity(raw, low[1])
        if value.nil?
          @empty = true
        else
          seek_key << value
          @strict_low = low[2] && unchanged?(raw, value)
        end
      end
      @has_high = false
      @strict_high = false
      if high = @high_bound
        raw = high[0].evaluate(frame)
        value = ValueSemantics.apply_record_affinity(raw, high[1])
        if value.nil?
          @empty = true
        else
          @high = value
          @has_high = true
          @strict_high = high[2] && unchanged?(raw, value)
        end
      end
      index_cursor = @index_cursor ||= IndexCursor.new(@database, @root_page, @order)
      unless @opened_for.same?(frame)
        index_cursor.forget_position
        @opened_for = frame
      end
      @table_cursor ||= TableCursor.new(@database, @table.root_page)
    end

    @opened_for : Frame? = nil

    # True when converting a bound kept its value exactly: an entry equal
    # to a rounded bound may still pass the WHERE term, so only an exact
    # bound skips the entries equal to it.
    private def unchanged?(raw : Value, converted : Value) : Bool
      case raw
      when Int64   then converted.is_a?(Int64) && converted == raw
      when Float64 then converted.is_a?(Float64) && converted == raw
      when String  then converted.is_a?(String) && converted == raw
      else              false
      end
    end

    @seek_key = [] of Value
    @entry = [] of Value
    @covering_checked : Bool? = nil

    # Rechecks at run time that the key columns hold every column read.
    private def covering_holds?(positions : Array(Int32)) : Bool
      checked = @covering_checked
      return checked unless checked.nil?
      alias_index = @table.rowid_alias
      holds = !@use.all? && (0...@table.list_of_column_names.size).all? do |column|
        !@use.includes?(column) || column == alias_index || positions.includes?(column)
      end
      @covering_checked = holds
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      return false if @empty
      index_cursor = @index_cursor
      table_cursor = @table_cursor
      return false unless index_cursor && table_cursor
      loop do
        moved = @started ? index_cursor.advance : (@seek_key.empty? ? index_cursor.first : index_cursor.seek(@seek_key, @strict_low))
        @started = true
        return false unless moved
        entry = index_cursor.record(@entry)
        unless @probe.empty? || @order.compare(entry, @probe) == 0
          @empty = true
          return false
        end
        if @has_high
          position = @probe.size
          collation = @order.collations[position]? || Collation::Binary
          beyond = ValueSemantics.compare(entry[position]?, @high, collation)
          if beyond > 0 || (@strict_high && beyond == 0)
            @empty = true
            return false
          end
        end
        rowid = entry.last?
        next unless rowid.is_a?(Int64)
        # A covering index (every column read is a key column) gives the
        # row without the table (SQLite's "USING COVERING INDEX").
        if (covering = @covering) && covering_holds?(covering)
          frame.list_of_rows[@slot] = @table.row_from_index(rowid, entry, covering, @buffer)
          frame.list_of_rowids[@slot] = rowid
          return true
        end
        next unless table_cursor.seek(rowid) && table_cursor.rowid == rowid
        table_cursor.row(@table, @use, @buffer)
        frame.list_of_rows[@slot] = @buffer
        frame.list_of_rowids[@slot] = rowid
        return true
      end
    end
  end

  # Rows computed by a query (a subquery or view in FROM, a CTE, VALUES,
  # a table-valued function), kept for the execution unless the query
  # refers to an outer row.
  # Rows are read from the producer as the outer query asks for them (a
  # co-routine, so an outer LIMIT stops an unbounded recursive CTE) and
  # kept, so a later pass for the next outer row reads them again.
  class MaterializedSource < RowSource
    @rows = [] of Array(Value)
    @exhausted = false
    @computed_for : Frame? = nil
    @position = 0

    def initialize(@slot : Int32, @producer : Producer, @correlated : Bool)
    end

    def open(frame : Frame) : Nil
      if @correlated || !@computed_for.same?(frame)
        @rows = [] of Array(Value)
        @exhausted = false
        @producer.open(frame)
        @computed_for = frame
      end
      @position = 0
    end

    def advance(frame : Frame) : Bool
      frame.session.tick
      if @position >= @rows.size
        return false if @exhausted
        row = @producer.next_row(frame)
        unless row
          @exhausted = true
          return false
        end
        @rows << row
      end
      frame.list_of_rows[@slot] = @rows[@position]
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
