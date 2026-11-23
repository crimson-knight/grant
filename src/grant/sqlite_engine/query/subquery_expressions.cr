module Grant::SQLiteEngine::Query
  # Shared by the subquery expressions: runs the query again for each outer
  # row when it refers to one, once per execution otherwise.
  abstract class SubqueryExpr < Expr
    getter list_of_outer_slots : Set(Int32)
    @correlated : Bool

    def initialize(@producer : Producer, @list_of_outer_slots : Set(Int32))
      @correlated = !@list_of_outer_slots.empty?
    end

    @computed_for : Frame? = nil

    # True when the cached result can be reused for this evaluation.
    protected def cached?(frame : Frame) : Bool
      !@correlated && @computed_for.same?(frame)
    end

    protected def remember(frame : Frame) : Nil
      @computed_for = frame
    end

    def constant? : Bool
      !@correlated
    end
  end

  # `(SELECT ...)` as a value: the first column of the first row, or NULL.
  class ScalarSubqueryExpr < SubqueryExpr
    @value : Value = nil

    def initialize(producer : Producer, outer_slots : Set(Int32), @result_affinity : ExpressionAffinity)
      super(producer, outer_slots)
    end

    def evaluate(frame : Frame) : Value
      return @value if cached?(frame)
      @producer.open(frame)
      row = @producer.next_row(frame)
      @value = row ? row[0]? : nil
      remember(frame)
      @value
    end

    def affinity : ExpressionAffinity
      @result_affinity
    end
  end

  # `EXISTS (SELECT ...)`.
  class ExistsExpr < SubqueryExpr
    @value : Value = 0_i64

    def evaluate(frame : Frame) : Value
      return @value if cached?(frame)
      @producer.open(frame)
      @value = @producer.next_row(frame) ? 1_i64 : 0_i64
      remember(frame)
      @value
    end
  end

  # `x IN (SELECT ...)` and `(x, y) IN (SELECT ...)`. The subquery's rows
  # form a set, each column converted with the affinity
  # sqlite3CompareAffinity gives it against the left operand and compared
  # with sqlite3BinaryCompareCollSeq's collation; the left values get the
  # same affinity.
  class InSelectExpr < SubqueryExpr
    @keys = Set(Array(EqualityKey)).new
    @rows = [] of Array(Value)
    @has_null_row = false
    @empty = true

    def initialize(producer : Producer, outer_slots : Set(Int32), @list_of_operands : Array(Expr),
                   @list_of_affinities : Array(ExpressionAffinity), @list_of_collations : Array(Collation), @negated : Bool,
                   @nulls_from_first_entry_only : Bool = false)
      super(producer, outer_slots)
      mark_collate_from(@list_of_operands)
    end

    def evaluate(frame : Frame) : Value
      load(frame) unless cached?(frame)
      return (@negated ? 1_i64 : 0_i64) if @empty
      values = @list_of_operands.map_with_index do |operand, index|
        ValueSemantics.apply_record_affinity(operand.evaluate(frame), @list_of_affinities[index])
      end
      found = values.size == 1 ? single(values[0]) : vector(values)
      return nil if found.nil?
      found == @negated ? 0_i64 : 1_i64
    end

    private def single(value : Value) : Bool?
      return nil if value.nil?
      return true if @keys.includes?([ValueSemantics.equality_key(value, @list_of_collations[0])])
      @has_null_row ? nil : false
    end

    # True on a row equal in every column; nil when no row differs in a
    # column where both sides are non-NULL but some row was left undecided
    # by NULLs.
    private def vector(values : Array(Value)) : Bool?
      undecided = false
      @rows.each do |row|
        mismatch = false
        unknown = false
        values.each_with_index do |value, index|
          other = row[index]?
          if value.nil? || other.nil?
            unknown = true
          elsif ValueSemantics.compare(value, other, @list_of_collations[index]) != 0
            mismatch = true
            break
          end
        end
        next if mismatch
        return true unless unknown
        undecided = true
      end
      undecided ? nil : false
    end

    private def load(frame : Frame) : Nil
      @keys = Set(Array(EqualityKey)).new
      @rows = [] of Array(Value)
      @has_null_row = false
      @empty = true
      @producer.open(frame)
      while row = @producer.next_row(frame)
        @empty = false
        converted = Array(Value).new(@list_of_operands.size) do |index|
          ValueSemantics.apply_record_affinity(row[index]?, @list_of_affinities[index])
        end
        if converted.size == 1
          if converted[0].nil?
            @has_null_row = true
          else
            @keys << [ValueSemantics.equality_key(converted[0], @list_of_collations[0])]
          end
        else
          @rows << converted
        end
      end
      # A DESC index's first entry is NULL only when every entry is.
      @has_null_row = @keys.empty? if @nulls_from_first_entry_only && !@empty
      remember(frame)
    end

    def collation_children : Array(Expr)
      @list_of_operands
    end
  end
end
