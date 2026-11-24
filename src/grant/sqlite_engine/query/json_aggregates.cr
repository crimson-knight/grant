module Grant::SQLiteEngine::Query
  # json_group_array and json_group_object, and their jsonb_ forms
  # (jsonArrayStep, jsonObjectStep and their finals in json.c of SQLite
  # 3.51.0). They read the subtype of the value they are given, so text
  # from a JSON function goes in as JSON.
  module JsonAggregates
    # Feeds the frame's row to a JSON aggregate: its arguments with their
    # subtypes, and DISTINCT kept on the values as C keeps it (a NULL is a
    # value like any other).
    def self.step(call : AggregateCall, accumulator : AggregateFunctions::Accumulator,
                  distinct_set : Set(Array(EqualityKey))?, frame : Frame) : Nil
      return unless accumulator.is_a?(GroupAccumulator)
      values = Array(Value).new(call.list_of_arguments.size)
      list_of_subtypes = Array(UInt8).new(call.list_of_arguments.size)
      call.list_of_arguments.each do |argument|
        value, subtype = argument.value_with_subtype(frame)
        values << value
        list_of_subtypes << subtype
      end
      if distinct_set
        distinct_key = values.map { |value| ValueSemantics.equality_key(value, call.collation) }
        return unless distinct_set.add?(distinct_key)
      end
      accumulator.step_with_subtypes(values, list_of_subtypes)
    end

    # The JSON text of one group, built a row at a time.
    abstract class GroupAccumulator < AggregateFunctions::Accumulator
      @output : Json::TextOutput? = nil

      def initialize(@binary : Bool)
      end

      abstract def step_with_subtypes(arguments : Array(Value), list_of_subtypes : Array(UInt8)) : Nil
      abstract def opening : Char
      abstract def closing : Char

      def step(arguments : Array(Value)) : Nil
        step_with_subtypes(arguments, Array(UInt8).new(arguments.size, 0_u8))
      end

      def step_one(value : Value) : Nil
        step_with_subtypes([value] of Value, [0_u8])
      end

      # The text so far; *separated* adds the comma a further member needs.
      private def output_for_next(separated : Bool) : Json::TextOutput
        if output = @output
          output.write_byte(','.ord.to_u8) if separated && output.size > 1
          return output
        end
        output = @output = Json::TextOutput.new
        output.write_byte(opening.ord.to_u8)
        output
      end

      # jsonArrayCompute / jsonObjectCompute: a group that took no row is
      # the empty container as text, for the jsonb_ forms too.
      def finish : Value
        output = @output
        return "#{opening}#{closing}" unless output
        raise Json.malformed if output.malformed?
        text = "#{output.to_s}#{closing}" # ameba:disable Lint/RedundantStringCoercion (TextOutput#to_s builds the text; it has no to_s(io))
        @binary ? Json.text_to_blob(text) : text
      end

      def reset : Nil
        @output = nil
      end
    end

    class GroupArrayAccumulator < GroupAccumulator
      def opening : Char
        '['
      end

      def closing : Char
        ']'
      end

      def step_with_subtypes(arguments : Array(Value), list_of_subtypes : Array(UInt8)) : Nil
        output = output_for_next(true)
        Json.append_sql_value(output, arguments[0], list_of_subtypes[0])
        raise SQLError.new("JSON cannot hold BLOB values") if output.holds_blob_error?
      end
    end

    class GroupObjectAccumulator < GroupAccumulator
      def opening : Char
        '{'
      end

      def closing : Char
        '}'
      end

      # A NULL name adds nothing; the name is its text up to a NUL.
      def step_with_subtypes(arguments : Array(Value), list_of_subtypes : Array(UInt8)) : Nil
        name = Json.path_text(arguments[0])
        output = output_for_next(!name.nil?)
        return unless name
        Json.append_string(output, name.to_slice)
        output.write_byte(':'.ord.to_u8)
        Json.append_sql_value(output, arguments[1], list_of_subtypes[1])
        raise SQLError.new("JSON cannot hold BLOB values") if output.holds_blob_error?
      end
    end
  end

  # The result of a JSON aggregate for the current group: its JSON text
  # carries JSON_SUBTYPE (the jsonb_ forms' BLOB does not).
  class JsonAggregateResultExpr < AggregateResultExpr
    def value_with_subtype(frame : Frame) : {Value, UInt8}
      value = evaluate(frame)
      {value, value.is_a?(String) ? Json::SUBTYPE : 0_u8}
    end
  end
end
