module Grant::SQLiteEngine::Query
  # sqlite3ExprDataType: a bit mask of the storage classes an expression
  # can produce (0x01 numeric, 0x02 text, 0x04 blob; 0 only NULL), which
  # sqlite3SubqueryColumnTypes uses to settle a compound column's affinity.
  abstract class Expr
    def data_type : Int32
      0x01
    end
  end

  class ConstantExpr
    def data_type : Int32
      case @value
      when Nil    then 0x00
      when String then 0x02
      when Bytes  then 0x04
      else             0x01
      end
    end
  end

  {% for name in %w[CollateExpr UnaryPlusExpr] %}
    class {{name.id}}
      def data_type : Int32
        @operand.data_type
      end
    end
  {% end %}

  class ConcatExpr
    def data_type : Int32
      0x06
    end
  end

  {% for name in %w[ParameterExpr AggregateResultExpr FunctionExpr UserFunctionExpr CoalesceExpr IifExpr PassThroughExpr] %}
    class {{name.id}}
      def data_type : Int32
        0x07
      end
    end
  {% end %}

  {% for name in %w[ColumnExpr RowidExpr CastExpr ScalarSubqueryExpr VectorExpr] %}
    class {{name.id}}
      def data_type : Int32
        Expr.data_type_of_affinity(affinity)
      end
    end
  {% end %}

  abstract class Expr
    def self.data_type_of_affinity(affinity : ExpressionAffinity) : Int32
      return 0x05 if affinity.numeric?
      return 0x06 if affinity.text?
      0x07
    end
  end

  class CaseExpr
    def data_type : Int32
      result = @results.reduce(0) { |mask, expression| mask | expression.data_type }
      if else_result = @else_result
        result |= else_result.data_type
      end
      result
    end
  end
end
