module Grant::SQLiteEngine::Query
  # How SQLite evaluates a condition it branches on (a WHERE, ON or HAVING
  # term, a CASE WHEN test): sqlite3ExprIfTrue and sqlite3ExprIfFalse,
  # which stop an AND or OR as soon as its outcome is known, and treat NULL
  # as a jump or not by the *jump_if_null* flag they pass down. Which
  # operands run decides which runtime errors a query raises, so the
  # engine follows the same order.
  abstract class Expr
    # Whether the branch is taken: with *if_true*, when the condition is
    # true; otherwise when it is false; NULL takes it when *jump_if_null*.
    def jump?(frame : Frame, if_true : Bool, jump_if_null : Bool) : Bool
      truth = ValueSemantics.truth(evaluate(frame))
      return jump_if_null if truth.nil?
      truth == if_true
    end

    # True when the condition holds: SQLite's
    # `sqlite3ExprIfFalse(term, skip, SQLITE_JUMPIFNULL)` does not jump.
    def holds?(frame : Frame) : Bool
      !jump?(frame, false, true)
    end

    # EP_Subquery: a subquery appears somewhere in the expression.
    def has_subquery? : Bool
      is_a?(SubqueryExpr) || children.any?(&.has_subquery?)
    end

    # ExprAlwaysTrue / ExprAlwaysFalse: an integer constant.
    def always_true? : Bool
      value = is_a?(ConstantExpr) ? evaluate_constant : nil
      value.is_a?(Int64) && value != 0
    end

    def always_false? : Bool
      value = is_a?(ConstantExpr) ? evaluate_constant : nil
      value.is_a?(Int64) && value == 0
    end

    protected def evaluate_constant : Value
      nil
    end
  end

  class ConstantExpr
    protected def evaluate_constant : Value
      @value
    end
  end

  class NotExpr
    def jump?(frame : Frame, if_true : Bool, jump_if_null : Bool) : Bool
      @operand.jump?(frame, !if_true, jump_if_null)
    end
  end

  class LogicalExpr
    @simplified : Expr? = nil
    @simplified_known = false
    @right_first : Bool? = nil

    # sqlite3ExprSimplifiedAndOr: `x AND 1` is x, `x OR 0` is x, `x AND 0`
    # is 0 (x is not evaluated).
    def simplified : Expr
      unless @simplified_known
        @simplified_known = true
        left = @left
        left = left.simplified if left.is_a?(LogicalExpr)
        right = @right
        right = right.simplified if right.is_a?(LogicalExpr)
        if left.always_true? || right.always_false?
          @simplified = @conjunction ? right : left
        elsif right.always_true? || left.always_false?
          @simplified = @conjunction ? left : right
        end
      end
      @simplified || self
    end

    # exprEvalRhsFirst: the right operand first when only the left one
    # holds a subquery.
    def right_first? : Bool
      known = @right_first
      return known unless known.nil?
      @right_first = @left.has_subquery? && !@right.has_subquery?
    end

    def jump?(frame : Frame, if_true : Bool, jump_if_null : Bool) : Bool
      alternative = simplified
      return alternative.jump?(frame, if_true, jump_if_null) unless alternative.same?(self)
      first, second = right_first? ? {@right, @left} : {@left, @right}
      if @conjunction
        if if_true
          return false if first.jump?(frame, false, !jump_if_null)
          second.jump?(frame, true, jump_if_null)
        else
          first.jump?(frame, false, jump_if_null) || second.jump?(frame, false, jump_if_null)
        end
      else
        if if_true
          first.jump?(frame, true, jump_if_null) || second.jump?(frame, true, jump_if_null)
        else
          return false if first.jump?(frame, true, !jump_if_null)
          second.jump?(frame, false, jump_if_null)
        end
      end
    end
  end
end
