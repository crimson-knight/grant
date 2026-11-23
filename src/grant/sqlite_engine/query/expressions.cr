module Grant::SQLiteEngine::Query
  alias ExpressionAffinity = ValueSemantics::ExpressionAffinity
  alias EqualityKey = ValueSemantics::EqualityKey

  # The state one execution of a statement evaluates against: the current
  # row of every FROM source (by slot), their rowids, the aggregate results
  # of the current group, and the bound parameters.
  class Frame
    getter list_of_rows : Array(Array(Value))
    getter list_of_rowids : Array(Int64?)
    getter list_of_aggregate_values : Array(Value)
    getter list_of_parameters : Array(Value)
    getter session : Session
    # Per slot, the table scan whose current row still has values to
    # decode (columns only its WHERE tests read, decided from the stored
    # record); nil when the row in the slot is complete.
    getter list_of_pending : Array(TableScanSource?)

    def initialize(slot_count : Int32, aggregate_count : Int32, @list_of_parameters : Array(Value), @session : Session)
      @list_of_rows = Array(Array(Value)).new(slot_count) { [] of Value }
      @list_of_rowids = Array(Int64?).new(slot_count, nil)
      @list_of_aggregate_values = Array(Value).new(aggregate_count, nil)
      @list_of_pending = Array(TableScanSource?).new(slot_count, nil)
    end

    # Decodes what the row in *slot* still lacks, before anything reads it.
    @[AlwaysInline]
    def complete_row(slot : Int32) : Nil
      if pending = @list_of_pending.unsafe_fetch(slot)
        pending.complete_row(self)
      end
    end
  end

  # A compiled expression: names already resolved to frame slots.
  abstract class Expr
    # sqlite3ExprAffinity.
    def affinity : ExpressionAffinity
      ExpressionAffinity::None
    end

    # EP_Collate: a COLLATE clause somewhere in the expression (not inside
    # subqueries).
    getter? explicit_collate = false

    abstract def evaluate(frame : Frame) : Value

    # The expressions sqlite3ExprCollSeq descends into when this expression
    # carries an explicit COLLATE: the left operand, then the right, then
    # the arguments.
    def collation_children : Array(Expr)
      [] of Expr
    end

    protected def mark_collate_from(children : Enumerable(Expr)) : Nil
      @explicit_collate = children.any?(&.explicit_collate?)
    end

    protected def explicit_collate=(@explicit_collate : Bool)
    end

    # sqlite3ExprCollSeq: the collation this expression compares with, or
    # nil for "none" (BINARY by default).
    def collation_sequence : Collation?
      return unless @explicit_collate
      chosen = collation_children.find(&.explicit_collate?)
      chosen.try(&.collation_sequence)
    end

    # The unknown collation name sqlite3ExprCollSeq would look up for this
    # expression (and fail on), found the way `collation_sequence` finds
    # the collation; nil when the collation is known or there is none.
    def unknown_collation : String?
      return unless @explicit_collate
      chosen = collation_children.find(&.explicit_collate?)
      chosen.try(&.unknown_collation)
    end

    # True when the expression's value cannot change during one execution.
    def constant? : Bool
      false
    end

    # True for a column of a table (TK_COLUMN), which keeps its name and
    # collation through unary plus and CAST.
    def column_name? : String?
      nil
    end
  end

  # sqlite3BinaryCompareCollSeq.
  def self.binary_collation(left : Expr, right : Expr?) : Collation
    if left.explicit_collate?
      return left.collation_sequence || Collation::Binary
    end
    if right && right.explicit_collate?
      return right.collation_sequence || Collation::Binary
    end
    left.collation_sequence || right.try(&.collation_sequence) || Collation::Binary
  end

  class ConstantExpr < Expr
    getter value : Value

    def initialize(@value : Value)
    end

    def evaluate(frame : Frame) : Value
      @value
    end

    def constant? : Bool
      true
    end
  end

  class ParameterExpr < Expr
    def initialize(@index : Int32)
    end

    def evaluate(frame : Frame) : Value
      frame.list_of_parameters[@index - 1]? || nil
    end

    def constant? : Bool
      true
    end
  end

  # A column of the row in *slot*.
  class ColumnExpr < Expr
    getter slot : Int32
    getter column : Int32
    getter column_affinity : ExpressionAffinity
    getter column_collation : Collation
    getter declared_name : String
    # An integer this column reads is shown as a real.
    getter? realify : Bool

    def initialize(@slot : Int32, @column : Int32, @column_affinity : ExpressionAffinity, @column_collation : Collation,
                   @declared_name : String, @realify : Bool = false)
    end

    def evaluate(frame : Frame) : Value
      frame.complete_row(@slot)
      value = frame.list_of_rows.unsafe_fetch(@slot)[@column]? || nil
      return value.to_f64 if @realify && value.is_a?(Int64)
      value
    end

    def affinity : ExpressionAffinity
      @column_affinity
    end

    def collation_sequence : Collation?
      @column_collation
    end

    def column_name? : String?
      @declared_name
    end
  end

  # The rowid of the row in *slot*.
  class RowidExpr < Expr
    getter slot : Int32

    def initialize(@slot : Int32, @name : String = "rowid")
    end

    def evaluate(frame : Frame) : Value
      frame.list_of_rowids.unsafe_fetch(@slot)
    end

    def affinity : ExpressionAffinity
      ExpressionAffinity::Integer
    end

    # A rowid (or its INTEGER PRIMARY KEY alias, which resolves to the
    # rowid) has no collation (sqlite3ExprCollSeq skips iColumn < 0), so a
    # comparison takes the other operand's.
    def collation_sequence : Collation?
      nil
    end

    def column_name? : String?
      @name
    end
  end

  # An aggregate's result for the current group.
  class AggregateResultExpr < Expr
    def initialize(@index : Int32)
    end

    def evaluate(frame : Frame) : Value
      frame.list_of_aggregate_values.unsafe_fetch(@index)
    end
  end

  # `expression COLLATE name`.
  class CollateExpr < Expr
    getter operand : Expr

    # *unknown_collation*: the name written, when no collation has it
    # (BINARY stands in; the error comes only where a comparison, sort or
    # aggregate uses the collation).
    getter unknown_collation : String?

    def initialize(@operand : Expr, @collation : Collation, @unknown_collation : String? = nil)
      self.explicit_collate = true
    end

    def evaluate(frame : Frame) : Value
      @operand.evaluate(frame)
    end

    def affinity : ExpressionAffinity
      @operand.affinity
    end

    def collation_sequence : Collation?
      @collation
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  # Unary `+`: the operand's value with no affinity.
  class UnaryPlusExpr < Expr
    def initialize(@operand : Expr)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      @operand.evaluate(frame)
    end

    def collation_sequence : Collation?
      @operand.collation_sequence
    end

    def constant? : Bool
      @operand.constant?
    end

    def column_name? : String?
      @operand.column_name?
    end
  end

  class CastExpr < Expr
    def initialize(@operand : Expr, @target : ValueSemantics::CastTarget, @target_affinity : ExpressionAffinity)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      ValueSemantics.cast(@operand.evaluate(frame), @target)
    end

    def affinity : ExpressionAffinity
      @target_affinity
    end

    def collation_sequence : Collation?
      @operand.collation_sequence
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  class ArithmeticExpr < Expr
    def initialize(@operator : ValueSemantics::Arithmetic, @left : Expr, @right : Expr)
      mark_collate_from({@left, @right})
    end

    def evaluate(frame : Frame) : Value
      ValueSemantics.arithmetic(@operator, @left.evaluate(frame), @right.evaluate(frame))
    end

    def collation_children : Array(Expr)
      [@left, @right] of Expr
    end

    def constant? : Bool
      @left.constant? && @right.constant?
    end
  end

  class BitwiseExpr < Expr
    def initialize(@operator : ValueSemantics::Bitwise, @left : Expr, @right : Expr)
      mark_collate_from({@left, @right})
    end

    def evaluate(frame : Frame) : Value
      ValueSemantics.bitwise(@operator, @left.evaluate(frame), @right.evaluate(frame))
    end

    def collation_children : Array(Expr)
      [@left, @right] of Expr
    end

    def constant? : Bool
      @left.constant? && @right.constant?
    end
  end

  class ConcatExpr < Expr
    def initialize(@left : Expr, @right : Expr)
      mark_collate_from({@left, @right})
    end

    def evaluate(frame : Frame) : Value
      left = @left.evaluate(frame)
      return if left.nil?
      right = @right.evaluate(frame)
      return if right.nil?
      "#{ValueSemantics.text(left)}#{ValueSemantics.text(right)}"
    end

    def collation_children : Array(Expr)
      [@left, @right] of Expr
    end

    def constant? : Bool
      @left.constant? && @right.constant?
    end
  end

  # `-x`, compiled by SQLite as `0 - x`.
  class NegateExpr < Expr
    def initialize(@operand : Expr)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      ValueSemantics.arithmetic(ValueSemantics::Arithmetic::Subtract, 0_i64, @operand.evaluate(frame))
    end

    def collation_children : Array(Expr)
      [@operand] of Expr
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  class BitNotExpr < Expr
    def initialize(@operand : Expr)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      value = @operand.evaluate(frame)
      value.nil? ? nil : ~ValueSemantics.integer_value(value)
    end

    def collation_children : Array(Expr)
      [@operand] of Expr
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  # TRUE or FALSE (TK_TRUEFALSE): an unresolved TRUE/FALSE identifier, or
  # `x IN ()`, which the parser replaces with one.
  class TrueFalseExpr < ConstantExpr
    def initialize(truth : Bool)
      super(truth ? 1_i64 : 0_i64)
    end

    def true? : Bool
      value == 1_i64
    end
  end

  # `x IS [NOT] TRUE` and `x IS [NOT] FALSE` (TK_TRUTH, OP_IsTrue): never
  # NULL; a NULL operand is not TRUE and not FALSE.
  class TruthExpr < Expr
    def initialize(@operand : Expr, @against_true : Bool, @negated : Bool)
    end

    def evaluate(frame : Frame) : Value
      truth = ValueSemantics.truth(@operand.evaluate(frame))
      matches = truth.nil? ? false : truth == @against_true
      matches != @negated ? 1_i64 : 0_i64
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  class NotExpr < Expr
    def initialize(@operand : Expr)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      truth = ValueSemantics.truth(@operand.evaluate(frame))
      truth.nil? ? nil : (truth ? 0_i64 : 1_i64)
    end

    def collation_children : Array(Expr)
      [@operand] of Expr
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  # AND and OR with SQL's three-valued logic.
  class LogicalExpr < Expr
    getter left : Expr
    getter right : Expr
    getter? conjunction : Bool
    # Built from `x BETWEEN low AND high` (x >= low AND x <= high).
    property? between = false

    def initialize(@conjunction : Bool, @left : Expr, @right : Expr)
      mark_collate_from({@left, @right})
    end

    # exprCodeTargetAndOr: as a value, both operands are evaluated, except
    # that an operand holding a subquery is skipped once the other one
    # settles the result (and the simplified form of a constant operand).
    def evaluate(frame : Frame) : Value
      alternative = simplified
      unless alternative.same?(self)
        truth = ValueSemantics.truth(alternative.evaluate(frame))
        return truth.nil? ? nil : (truth ? 1_i64 : 0_i64)
      end
      settled = @conjunction ? false : true
      if right_first?
        right = ValueSemantics.truth(@right.evaluate(frame))
        return (settled ? 1_i64 : 0_i64) if right == settled
        left = ValueSemantics.truth(@left.evaluate(frame))
      else
        left = ValueSemantics.truth(@left.evaluate(frame))
        return (settled ? 1_i64 : 0_i64) if left == settled && @right.has_subquery?
        right = ValueSemantics.truth(@right.evaluate(frame))
      end
      combine(left, right)
    end

    private def combine(left : Bool?, right : Bool?) : Value
      if @conjunction
        return 0_i64 if left == false || right == false
        left.nil? || right.nil? ? nil : 1_i64
      else
        return 1_i64 if left == true || right == true
        left.nil? || right.nil? ? nil : 0_i64
      end
    end

    def collation_children : Array(Expr)
      [@left, @right] of Expr
    end

    def constant? : Bool
      @left.constant? && @right.constant?
    end
  end

  enum ComparisonOperator
    Equal
    NotEqual
    Less
    LessOrEqual
    Greater
    GreaterOrEqual
    Is
    IsNot

    def holds?(comparison : Int32) : Bool
      case self
      in .equal?, .is?         then comparison == 0
      in .not_equal?, .is_not? then comparison != 0
      in .less?                then comparison < 0
      in .less_or_equal?       then comparison <= 0
      in .greater?             then comparison > 0
      in .greater_or_equal?    then comparison >= 0
      end
    end

    def null_safe? : Bool
      is? || is_not?
    end

    # The operator with its operands swapped.
    def commuted : ComparisonOperator
      case self
      when .less?             then Greater
      when .less_or_equal?    then GreaterOrEqual
      when .greater?          then Less
      when .greater_or_equal? then LessOrEqual
      else                         self
      end
    end
  end

  # A comparison of two values with the affinity and collation SQLite
  # chooses for the pair (codeCompare).
  class ComparisonExpr < Expr
    getter operator : ComparisonOperator
    getter left : Expr
    getter right : Expr
    getter comparison_affinity : ExpressionAffinity
    getter collation : Collation

    def initialize(@operator : ComparisonOperator, @left : Expr, @right : Expr)
      mark_collate_from({@left, @right})
      @comparison_affinity = ValueSemantics.comparison_affinity(@left.affinity, @right.affinity)
      @collation = Query.binary_collation(@left, @right)
    end

    def evaluate(frame : Frame) : Value
      ComparisonExpr.compare_values(@operator, @left.evaluate(frame), @right.evaluate(frame), @comparison_affinity, @collation)
    end

    def self.compare_values(operator : ComparisonOperator, left : Value, right : Value,
                            affinity : ExpressionAffinity, collation : Collation) : Value
      if left.nil? || right.nil?
        return unless operator.null_safe?
        both = left.nil? && right.nil?
        return (operator.is? ? both : !both) ? 1_i64 : 0_i64
      end
      either_is_text = left.is_a?(String) || right.is_a?(String)
      left = ValueSemantics.prepare_for_comparison(left, affinity, either_is_text)
      right = ValueSemantics.prepare_for_comparison(right, affinity, either_is_text)
      operator.holds?(ValueSemantics.compare(left, right, collation)) ? 1_i64 : 0_i64
    end

    def collation_children : Array(Expr)
      [@left, @right] of Expr
    end

    def constant? : Bool
      @left.constant? && @right.constant?
    end
  end

  # A row value `(a, b, ...)`, legal only as a comparison operand.
  class VectorExpr < Expr
    getter elements : Array(Expr)

    def initialize(@elements : Array(Expr))
      mark_collate_from(@elements)
    end

    def evaluate(frame : Frame) : Value
      raise SQLError.new("row value misused")
    end

    def affinity : ExpressionAffinity
      @elements.first.affinity
    end

    def collation_sequence : Collation?
      @elements.first.collation_sequence
    end

    def constant? : Bool
      @elements.all?(&.constant?)
    end
  end

  # A row-value comparison (rowvalue.html): element by element, the first
  # pair that differs decides; NULL where a NULL decides.
  class VectorComparisonExpr < Expr
    @pairs : Array({ExpressionAffinity, Collation})

    def initialize(@operator : ComparisonOperator, @left : Array(Expr), @right : Array(Expr))
      @pairs = @left.zip(@right).map do |pair|
        {ValueSemantics.comparison_affinity(pair[0].affinity, pair[1].affinity), Query.binary_collation(pair[0], pair[1])}
      end
    end

    def evaluate(frame : Frame) : Value
      left_values = @left.map(&.evaluate(frame))
      right_values = @right.map(&.evaluate(frame))
      VectorComparisonExpr.compare_rows(@operator, left_values, right_values, @pairs)
    end

    def self.compare_rows(operator : ComparisonOperator, left_values : Array(Value), right_values : Array(Value),
                          pairs : Array({ExpressionAffinity, Collation})) : Value
      if operator.equal? || operator.not_equal? || operator.is? || operator.is_not?
        saw_null = false
        left_values.each_with_index do |left, index|
          affinity, collation = pairs[index]
          equal = ComparisonExpr.compare_values(
            operator.null_safe? ? ComparisonOperator::Is : ComparisonOperator::Equal,
            left, right_values[index], affinity, collation)
          if equal.nil?
            saw_null = true
          elsif equal == 0_i64
            return operator.equal? || operator.is? ? 0_i64 : 1_i64
          end
        end
        return if saw_null
        return operator.equal? || operator.is? ? 1_i64 : 0_i64
      end
      last = left_values.size - 1
      left_values.each_with_index do |left, index|
        right = right_values[index]
        affinity, collation = pairs[index]
        return if left.nil? || right.nil?
        if index < last
          equal = ComparisonExpr.compare_values(ComparisonOperator::Equal, left, right, affinity, collation)
          next if equal == 1_i64
          strict = operator.less? || operator.less_or_equal? ? ComparisonOperator::Less : ComparisonOperator::Greater
          return ComparisonExpr.compare_values(strict, left, right, affinity, collation)
        end
        return ComparisonExpr.compare_values(operator, left, right, affinity, collation)
      end
      nil
    end

    def constant? : Bool
      @left.all?(&.constant?) && @right.all?(&.constant?)
    end
  end

  # `x ISNULL`, `x NOTNULL`, `x IS NULL`.
  class NullTestExpr < Expr
    getter operand : Expr
    getter? negated : Bool

    def initialize(@operand : Expr, @negated : Bool)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      (@operand.evaluate(frame).nil? != @negated) ? 1_i64 : 0_i64
    end

    def collation_children : Array(Expr)
      [@operand] of Expr
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  # `x IN (list)`. A list of up to two values, or one with a non-constant
  # value, is compared value by value like `x = +a OR x = +b` (the list has
  # no affinity); a longer constant list becomes a set, as SQLite builds an
  # ephemeral index from it, with the left operand's affinity applied to
  # both sides (sqlite3FindInIndex, sqlite3CodeRhsOfIN).
  class InListExpr < Expr
    getter operand : Expr
    getter list : Array(Expr)
    getter? negated : Bool
    @affinity_used : ExpressionAffinity
    @set_affinity : ExpressionAffinity
    @collation : Collation
    @as_set : Bool
    @cached_set : Hash(EqualityKey, Bool)? = nil
    @cached_set_has_null = false
    @cached_for : Frame? = nil

    def initialize(@operand : Expr, @list : Array(Expr), @negated : Bool)
      mark_collate_from([@operand] + @list)
      @affinity_used = @operand.affinity
      @set_affinity = InListExpr.comparison_affinity_of_set(@operand.affinity)
      @collation = @operand.collation_sequence || Collation::Binary
      @as_set = @list.size > 2 && @list.all?(&.constant?)
    end

    # The affinity SQLite gives an IN set built from a list.
    def self.comparison_affinity_of_set(left : ExpressionAffinity) : ExpressionAffinity
      return ExpressionAffinity::Blob if left.none?
      return ExpressionAffinity::Numeric if left.real?
      left
    end

    def evaluate(frame : Frame) : Value
      return (@negated ? 1_i64 : 0_i64) if @list.empty?
      value = @operand.evaluate(frame)
      return if value.nil?
      found = @as_set ? set_lookup(value, frame) : scan(value, frame)
      return if found.nil?
      found == @negated ? 0_i64 : 1_i64
    end

    # nil when no entry matched but one was NULL.
    private def scan(value : Value, frame : Frame) : Bool?
      saw_null = false
      @list.each do |entry|
        candidate = entry.evaluate(frame)
        if candidate.nil?
          saw_null = true
          next
        end
        if ComparisonExpr.compare_values(ComparisonOperator::Equal, value, candidate, @affinity_used, @collation) == 1_i64
          return true
        end
      end
      saw_null ? nil : false
    end

    private def set_lookup(value : Value, frame : Frame) : Bool?
      unless @cached_for.same?(frame)
        @cached_set = nil
        @cached_set_has_null = false
        @cached_for = frame
      end
      set = @cached_set ||= begin
        entries = {} of EqualityKey => Bool
        @list.each do |entry|
          candidate = ValueSemantics.apply_record_affinity(entry.evaluate(frame), @set_affinity)
          if candidate.nil?
            @cached_set_has_null = true
          else
            entries[ValueSemantics.equality_key(candidate, @collation)] = true
          end
        end
        entries
      end
      probe = ValueSemantics.apply_record_affinity(value, @set_affinity)
      return true if set.has_key?(ValueSemantics.equality_key(probe, @collation))
      @cached_set_has_null ? nil : false
    end

    def collation_children : Array(Expr)
      [@operand] + @list
    end

    def constant? : Bool
      @operand.constant? && @list.all?(&.constant?)
    end
  end

  # `CASE [operand] WHEN ... THEN ... [ELSE ...] END`.
  class CaseExpr < Expr
    @comparisons : Array(ComparisonExpr)?

    def initialize(@operand : Expr?, @conditions : Array(Expr), @results : Array(Expr), @else_result : Expr?)
      children = [] of Expr
      operand = @operand
      children << operand if operand
      children.concat(@conditions)
      children.concat(@results)
      else_result = @else_result
      children << else_result if else_result
      mark_collate_from(children)
      if operand
        @comparisons = @conditions.map { |condition| ComparisonExpr.new(ComparisonOperator::Equal, operand, condition) }
      end
    end

    def evaluate(frame : Frame) : Value
      operand = @operand
      if (comparisons = @comparisons) && operand
        value = operand.evaluate(frame)
        comparisons.each_with_index do |comparison, index|
          candidate = @conditions[index].evaluate(frame)
          if ComparisonExpr.compare_values(ComparisonOperator::Equal, value, candidate, comparison.comparison_affinity, comparison.collation) == 1_i64
            return @results[index].evaluate(frame)
          end
        end
      else
        @conditions.each_with_index do |condition, index|
          return @results[index].evaluate(frame) if condition.holds?(frame)
        end
      end
      @else_result.try(&.evaluate(frame))
    end

    def collation_children : Array(Expr)
      list = [] of Expr
      if operand = @operand
        list << operand
      end
      list.concat(@conditions).concat(@results)
      if else_result = @else_result
        list << else_result
      end
      list
    end

    def constant? : Bool
      (@operand.try(&.constant?) != false) && @conditions.all?(&.constant?) &&
        @results.all?(&.constant?) && (@else_result.try(&.constant?) != false)
    end
  end

  # coalesce() and ifnull(): the first non-NULL argument, later arguments
  # left unevaluated.
  class CoalesceExpr < Expr
    def initialize(@arguments : Array(Expr))
      mark_collate_from(@arguments)
    end

    def evaluate(frame : Frame) : Value
      @arguments.each do |argument|
        value = argument.evaluate(frame)
        return value unless value.nil?
      end
      nil
    end

    def collation_children : Array(Expr)
      @arguments
    end

    def constant? : Bool
      @arguments.all?(&.constant?)
    end
  end

  # iif(condition, then, else) and if(...): pairs of condition and result,
  # with an optional final else.
  class IifExpr < Expr
    def initialize(@arguments : Array(Expr))
      mark_collate_from(@arguments)
    end

    def evaluate(frame : Frame) : Value
      index = 0
      while index + 1 < @arguments.size
        return @arguments[index + 1].evaluate(frame) if @arguments[index].holds?(frame)
        index += 2
      end
      index < @arguments.size ? @arguments[index].evaluate(frame) : nil
    end

    def collation_children : Array(Expr)
      @arguments
    end

    def constant? : Bool
      @arguments.all?(&.constant?)
    end
  end

  # likely(x), unlikely(x), likelihood(x, p): x itself, without x's
  # affinity (a function call has none; whereG.test 3.1-3.4).
  class PassThroughExpr < Expr
    def initialize(@operand : Expr)
      mark_collate_from({@operand})
    end

    def evaluate(frame : Frame) : Value
      @operand.evaluate(frame)
    end

    def collation_children : Array(Expr)
      [@operand] of Expr
    end

    def constant? : Bool
      @operand.constant?
    end
  end

  # A call to a built-in scalar function.
  class FunctionExpr < Expr
    @scratch : Array(Value)

    def function_name : String
      @definition.name
    end

    # The unknown collation this function's comparisons would look up.
    getter needed_unknown_collation : String? = nil

    def initialize(@definition : ScalarFunctions::Definition, @arguments : Array(Expr))
      mark_collate_from(@arguments)
      @collation = Collation::Binary
      if @definition.needs_collation
        @collation = @arguments.compact_map(&.collation_sequence).first? || Collation::Binary
      end
      @needed_unknown_collation = @definition.needs_collation ? @arguments.find(&.explicit_collate?).try(&.unknown_collation) : nil
      @scratch = Array(Value).new(@arguments.size, nil)
      @deterministic = !@definition.name.in?("random", "randomblob", "changes", "last_insert_rowid", "total_changes")
    end

    def evaluate(frame : Frame) : Value
      values = Array(Value).new(@arguments.size) { |index| @arguments.unsafe_fetch(index).evaluate(frame) }
      @definition.implementation.call(values, ScalarFunctions::CallContext.new(@collation, frame.session))
    end

    def collation_children : Array(Expr)
      @arguments
    end

    def constant? : Bool
      @deterministic && @arguments.all?(&.constant?)
    end
  end

  # A function the application registered on the connection (REGEXP).
  class UserFunctionExpr < Expr
    def initialize(@name : String, @function : Session::UserFunction, @arguments : Array(Expr))
      mark_collate_from(@arguments)
    end

    def evaluate(frame : Frame) : Value
      values = @arguments.map(&.evaluate(frame))
      begin
        @function.call(values)
      rescue error : SQLError
        raise error
      rescue error : Exception
        raise SQLError.new(error.message || "user function #{@name} failed")
      end
    end

    def collation_children : Array(Expr)
      @arguments
    end
  end

  # `x LIKE y [ESCAPE z]`, `x GLOB y`, `x REGEXP y` (the user function
  # regexp(y, x)), with NOT.
  class LikeExpr < Expr
    def initialize(@operand : Expr, @pattern : Expr, @escape : Expr?, @glob : Bool, @negated : Bool)
      children = [@operand, @pattern] of Expr
      if escape = @escape
        children << escape
      end
      mark_collate_from(children)
    end

    @cached_pattern : String? = nil
    @cached_prefix : Bytes? = nil

    getter operand : Expr
    getter pattern : Expr

    # The result for a text *subject* given as its UTF-8 bytes, when the
    # pattern is a literal prefix (as `evaluate` decides it); nil when
    # `evaluate` must decide.
    def prefix_verdict(frame : Frame, subject : Bytes) : Bool?
      return if @glob || @escape
      pattern = @pattern.evaluate(frame)
      return unless pattern.is_a?(String)
      prefix = literal_prefix(pattern)
      return unless prefix
      prefix_matches?(subject, prefix) != @negated
    end

    def evaluate(frame : Frame) : Value
      pattern = @pattern.evaluate(frame)
      if !@glob && @escape.nil? && pattern.is_a?(String) && (prefix = literal_prefix(pattern))
        subject = @operand.evaluate(frame)
        if subject.is_a?(String)
          return negate(prefix_matches?(subject.to_slice, prefix) ? 1_i64 : 0_i64)
        end
        return negate(ScalarFunctions.like([pattern, subject] of Value, @glob))
      end
      arguments = [pattern, @operand.evaluate(frame)] of Value
      if escape = @escape
        arguments << escape.evaluate(frame)
      end
      negate(ScalarFunctions.like(arguments, @glob))
    end

    private def negate(result : Value) : Value
      return result if result.nil? || !@negated
      result == 1_i64 ? 0_i64 : 1_i64
    end

    # A LIKE pattern of ASCII literal characters ending in one `%` matches
    # exactly the texts that start with those characters, ASCII case
    # folded (patternCompare returns SQLITE_MATCH at a final `%`). The
    # prefix is kept for the pattern object the last row used.
    private def literal_prefix(pattern : String) : Bytes?
      return @cached_prefix if pattern.same?(@cached_pattern)
      bytes = pattern.to_slice
      prefix = nil
      if bytes.size > 0 && bytes.size <= 1000 && bytes[-1] == '%'.ord
        candidate = bytes[0, bytes.size - 1]
        simple = candidate.all? { |byte| byte < 0x80 && byte != 0 && byte != '%'.ord && byte != '_'.ord }
        prefix = candidate if simple
      end
      @cached_pattern = pattern
      @cached_prefix = prefix
    end

    private def prefix_matches?(subject : Bytes, prefix : Bytes) : Bool
      return false if subject.size < prefix.size
      prefix.each_with_index do |byte, index|
        other = subject.unsafe_fetch(index)
        next if other == byte
        return false unless ascii_lower(other) == ascii_lower(byte)
      end
      true
    end

    private def ascii_lower(byte : UInt8) : UInt8
      byte >= 'A'.ord && byte <= 'Z'.ord ? byte + 32 : byte
    end

    def collation_children : Array(Expr)
      [@operand, @pattern] of Expr
    end

    def constant? : Bool
      @operand.constant? && @pattern.constant? && (@escape.try(&.constant?) != false)
    end
  end
end
