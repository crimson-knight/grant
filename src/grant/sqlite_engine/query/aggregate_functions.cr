module Grant::SQLiteEngine::Query
  # SQLite's aggregate functions (lang_aggfunc.html): count, sum, total,
  # avg, min, max, group_concat and string_agg, with the step and final
  # rules of func.c in SQLite 3.51.0 (sum's integer overflow error and its
  # Kahan-Babuska-Neumaier compensated real sum included).
  module AggregateFunctions
    enum Kind
      CountRows # count(*)
      Count
      Sum
      Total
      Average
      Min
      Max
      GroupConcat
    end

    # The aggregate *name* with *count* arguments, or nil when *name* is not
    # an aggregate. `count(*)` is `star`.
    def self.kind_for(name : String, count : Int32, star : Bool) : Kind?
      case name.downcase
      when "count"
        return Kind::CountRows if star || count == 0
        return Kind::Count if count == 1
        raise SQLError.new("wrong number of arguments to function #{name}()")
      when "sum", "total", "avg"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 1
        name.downcase == "sum" ? Kind::Sum : (name.downcase == "total" ? Kind::Total : Kind::Average)
      when "min", "max"
        return unless count == 1
        name.downcase == "min" ? Kind::Min : Kind::Max
      when "group_concat"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 1 || count == 2
        Kind::GroupConcat
      when "string_agg"
        raise SQLError.new("wrong number of arguments to function #{name}()") unless count == 2
        Kind::GroupConcat
      end
    end

    # The running state of one aggregate over one group.
    abstract class Accumulator
      abstract def step(arguments : Array(Value)) : Nil
      abstract def finish : Value

      # Starts over for a new group, as a new accumulator would.
      abstract def reset : Nil

      # For min and max: whether the last step changed the result, which
      # decides whether bare columns are reloaded from that row.
      def hit? : Bool
        true
      end

      def self.for(kind : Kind, collation : Collation) : Accumulator
        case kind
        in .count_rows?   then CountAccumulator.new(count_nulls: true)
        in .count?        then CountAccumulator.new(count_nulls: false)
        in .sum?          then SumAccumulator.new(SumAccumulator::Result::Sum)
        in .total?        then SumAccumulator.new(SumAccumulator::Result::Total)
        in .average?      then SumAccumulator.new(SumAccumulator::Result::Average)
        in .min?          then MinMaxAccumulator.new(collation, maximum: false)
        in .max?          then MinMaxAccumulator.new(collation, maximum: true)
        in .group_concat? then GroupConcatAccumulator.new
        end
      end
    end

    class CountAccumulator < Accumulator
      @count = 0_i64

      def initialize(@count_nulls : Bool)
      end

      def step(arguments : Array(Value)) : Nil
        @count += 1 if @count_nulls || !arguments[0].nil?
      end

      def finish : Value
        @count
      end

      def reset : Nil
        @count = 0_i64
      end
    end

    # sumStep, sumFinalize, totalFinalize and avgFinalize.
    class SumAccumulator < Accumulator
      enum Result
        Sum
        Total
        Average
      end

      @count = 0_i64
      @integer_sum = 0_i64
      @real_sum = 0.0
      @error_term = 0.0
      @approximate = false
      @overflowed = false

      def initialize(@result : Result)
      end

      def step(arguments : Array(Value)) : Nil
        value = arguments[0]
        value = ValueSemantics.comparison_numeric(value) if value.is_a?(String)
        return if value.nil?
        @count += 1
        if !@approximate
          if value.is_a?(Int64)
            total = @integer_sum &+ value
            if ((@integer_sum ^ total) & (value ^ total)) >= 0
              @integer_sum = total
            else
              @overflowed = true
              start_approximation(@integer_sum)
              add_integer(value)
            end
          else
            start_approximation(@integer_sum)
            add_real(ValueSemantics.real_value(value))
          end
        elsif value.is_a?(Int64)
          add_integer(value)
        else
          @overflowed = false
          add_real(ValueSemantics.real_value(value))
        end
      end

      def finish : Value
        case @result
        in .sum?
          return if @count == 0
          return @integer_sum unless @approximate
          raise SQLError.new("integer overflow") if @overflowed
          @error_term.finite? ? @real_sum + @error_term : @real_sum
        in .total?
          combined
        in .average?
          return if @count == 0
          combined / @count.to_f64
        end
      end

      def reset : Nil
        @count = 0_i64
        @integer_sum = 0_i64
        @real_sum = 0.0
        @error_term = 0.0
        @approximate = false
        @overflowed = false
      end

      private def combined : Float64
        return @integer_sum.to_f64 unless @approximate
        @error_term.finite? ? @real_sum + @error_term : @real_sum
      end

      # kahanBabuskaNeumaierInit.
      private def start_approximation(integer : Int64) : Nil
        @approximate = true
        if integer <= -4503599627370496_i64 || integer >= 4503599627370496_i64
          small = integer.remainder(16384)
          @real_sum = (integer - small).to_f64
          @error_term = small.to_f64
        else
          @real_sum = integer.to_f64
          @error_term = 0.0
        end
      end

      # kahanBabuskaNeumaierStepInt64.
      private def add_integer(integer : Int64) : Nil
        if integer <= -4503599627370496_i64 || integer >= 4503599627370496_i64
          small = integer.remainder(16384)
          add_real((integer - small).to_f64)
          add_real(small.to_f64)
        else
          add_real(integer.to_f64)
        end
      end

      # kahanBabuskaNeumaierStep.
      private def add_real(real : Float64) : Nil
        sum = @real_sum
        total = sum + real
        if sum.abs > real.abs
          @error_term += (sum - total) + real
        else
          @error_term += (real - total) + sum
        end
        @real_sum = total
      end
    end

    # minmaxStep: NULLs are skipped; a new best replaces the old only when
    # strictly smaller (min) or larger (max).
    class MinMaxAccumulator < Accumulator
      @best : Value = nil
      @has_value = false
      @hit = false

      def initialize(@collation : Collation, @maximum : Bool)
      end

      def step(arguments : Array(Value)) : Nil
        value = arguments[0]
        # sqlite3SkipAccumulatorLoad: a NULL after a value, or a value that
        # does not replace the best, leaves the bare columns as they were.
        @hit = !@has_value
        return if value.nil?
        unless @has_value
          @best = value
          @has_value = true
          @hit = true
          return
        end
        comparison = ValueSemantics.compare(@best, value, @collation)
        if (@maximum && comparison < 0) || (!@maximum && comparison > 0)
          @best = value
          @hit = true
        end
      end

      def hit? : Bool
        @hit
      end

      def finish : Value
        @best
      end

      def reset : Nil
        @best = nil
        @has_value = false
        @hit = false
      end
    end

    class GroupConcatAccumulator < Accumulator
      @buffer : IO::Memory? = nil

      def step(arguments : Array(Value)) : Nil
        return if arguments[0].nil?
        buffer = @buffer
        if buffer
          if arguments.size == 1
            buffer << ','
          elsif separator = ValueSemantics.text(arguments[1])
            buffer << separator
          end
        else
          buffer = @buffer = IO::Memory.new
        end
        if piece = ValueSemantics.text(arguments[0])
          buffer << piece
        end
      end

      def finish : Value
        buffer = @buffer
        buffer ? String.new(buffer.to_slice) : nil
      end

      def reset : Nil
        @buffer = nil
      end
    end
  end
end
