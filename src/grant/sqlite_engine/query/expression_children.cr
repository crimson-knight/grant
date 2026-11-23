module Grant::SQLiteEngine::Query
  # Every operand of each compiled expression, for the planner's question
  # "which frame slots does this term read". Subqueries list their operands
  # here and their outer slots through `SubqueryExpr#list_of_outer_slots`.
  abstract class Expr
    def children : Array(Expr)
      [] of Expr
    end
  end

  {% for name in %w[CollateExpr UnaryPlusExpr CastExpr NegateExpr BitNotExpr NotExpr NullTestExpr PassThroughExpr] %}
    class {{name.id}}
      def children : Array(Expr)
        [@operand] of Expr
      end
    end
  {% end %}

  {% for name in %w[ArithmeticExpr BitwiseExpr ConcatExpr LogicalExpr ComparisonExpr] %}
    class {{name.id}}
      def children : Array(Expr)
        [@left, @right] of Expr
      end
    end
  {% end %}

  {% for name in %w[CoalesceExpr IifExpr FunctionExpr UserFunctionExpr] %}
    class {{name.id}}
      def children : Array(Expr)
        @arguments.map(&.as(Expr))
      end
    end
  {% end %}

  class VectorExpr
    def children : Array(Expr)
      @elements.map(&.as(Expr))
    end
  end

  class VectorComparisonExpr
    def children : Array(Expr)
      (@left + @right).map(&.as(Expr))
    end
  end

  class InListExpr
    def children : Array(Expr)
      [@operand] + @list
    end
  end

  class CaseExpr
    def children : Array(Expr)
      list = [] of Expr
      @operand.try { |operand| list << operand }
      list.concat(@conditions)
      list.concat(@results)
      @else_result.try { |else_result| list << else_result }
      list
    end
  end

  class LikeExpr
    def children : Array(Expr)
      list = [@operand, @pattern] of Expr
      @escape.try { |escape| list << escape }
      list
    end
  end

  class InSelectExpr
    def children : Array(Expr)
      @list_of_operands.map(&.as(Expr))
    end
  end
end
