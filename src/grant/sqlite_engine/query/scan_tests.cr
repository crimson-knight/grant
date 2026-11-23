module Grant::SQLiteEngine::Query
  # A WHERE term a table scan decides from the stored record, before any
  # value of the row is decoded into the frame: C SQLite's OP_Column
  # reads a number straight into a register, and its comparison opcodes
  # compare the registers without building a value. Each test gives the
  # term's truth when the stored value lets it (a number, or text for a
  # literal-prefix LIKE), and nil when the term must be evaluated the
  # general way (NULL for IS, a DEFAULT the record predates, text, blobs).
  abstract class ScanTest
    # True or false when the term's truth is known from *header*; nil
    # when the caller must evaluate the term.
    abstract def verdict(header : RecordHeader, frame : Frame) : Bool?

    # The test for *term* on the rows of *table* in *slot*, or nil when the
    # term has none.
    def self.for(term : Expr, slot : Int32, table : TableInfo, encoding : TextEncoding) : ScanTest?
      if term.is_a?(ComparisonExpr)
        comparison_test(term, slot, table)
      elsif term.is_a?(LikeExpr) && encoding.utf8?
        like_test(term, slot, table)
      end
    end

    private def self.comparison_test(term : ComparisonExpr, slot : Int32, table : TableInfo) : ScanTest?
      operator = term.operator
      column = term.left
      value = term.right
      unless stored_column?(column, slot, table)
        column, value = value, column
        operator = operator.commuted
      end
      return unless column.is_a?(ColumnExpr) && stored_column?(column, slot, table)
      return unless fixed_operand?(value, slot)
      position = table.stored_position(column.column)
      return unless position
      real = table.list_of_affinities[column.column].real? || column.realify?
      NumericComparisonTest.new(position, operator, value, real)
    end

    private def self.like_test(term : LikeExpr, slot : Int32, table : TableInfo) : ScanTest?
      operand = term.operand
      pattern = term.pattern
      return unless operand.is_a?(ColumnExpr) && stored_column?(operand, slot, table)
      return unless pattern.is_a?(ParameterExpr) || pattern.is_a?(ConstantExpr)
      position = table.stored_position(operand.column)
      position ? LikePrefixTest.new(position, term) : nil
    end

    # An operand that reads nothing of the row in *slot* and cannot fail:
    # a parameter, a literal, or a column or rowid of an earlier row.
    private def self.fixed_operand?(expression : Expr, slot : Int32) : Bool
      case expression
      when ParameterExpr, ConstantExpr then true
      when ColumnExpr                  then expression.slot != slot
      when RowidExpr                   then expression.slot != slot
      else                                  false
      end
    end

    # A column of the table in *slot* that its records store (the rowid
    # alias reads the rowid instead).
    private def self.stored_column?(expression : Expr, slot : Int32, table : TableInfo) : Bool
      expression.is_a?(ColumnExpr) && expression.slot == slot && expression.column != table.rowid_alias
    end
  end

  # `column <op> value` where the stored value and *value* are numbers:
  # with two numbers no comparison affinity changes either one (NUMERIC
  # converts only text, and TEXT converts numbers only beside text), so the
  # result is sqlite3MemCompare's. A REAL column reads an integer as a real,
  # as the frame would show it.
  class NumericComparisonTest < ScanTest
    def initialize(@position : Int32, @operator : ComparisonOperator, @value : Expr, @real : Bool)
    end

    def verdict(header : RecordHeader, frame : Frame) : Bool?
      return unless header.has?(@position)
      stored = header.number(@position)
      unless stored
        # A NULL makes the comparison NULL, which fails the term; IS and
        # IS NOT decide NULL themselves.
        return header.serial_type(@position) == 0 && !@operator.null_safe? ? false : nil
      end
      other = Expr.value_of(@value, frame)
      return unless other.is_a?(Int64) || other.is_a?(Float64)
      stored = stored.to_f64 if @real && stored.is_a?(Int64)
      @operator.holds?(ValueSemantics.compare(stored, other))
    end
  end

  # `column LIKE 'prefix%'` on stored UTF-8 text, decided from the bytes
  # (LikeExpr#prefix_verdict, the result `evaluate` gives for that text).
  class LikePrefixTest < ScanTest
    def initialize(@position : Int32, @like : LikeExpr)
    end

    def verdict(header : RecordHeader, frame : Frame) : Bool?
      return unless header.has?(@position)
      text = header.text_bytes(@position)
      return unless text
      @like.prefix_verdict(frame, text)
    end
  end
end
