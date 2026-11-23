# Declared as nested modules so this file loads whether or not the SQLite
# adapter is required.
module Grant
  module SQLite3
    # :nodoc:
    #
    # The `regexp(pattern, text)` SQL function, which SQLite runs for
    # `text REGEXP pattern`. It is opt-in: once `require "grant/regex"` defines this
    # module, every Grant SQLite connection registers it through its engine's
    # user-function call. It follows SQLite's conventions for extension
    # functions: a NULL argument gives NULL, and a bad pattern or bad text raises,
    # which the engine reports as the call's SQL error; the calling query then
    # raises it as a `Grant::SQLite3::Exception` on the fiber that ran it.
    module RegexpFunction
      ARGUMENT_COUNT = 2

      # Evaluates one call: 1 when the text matches the pattern, 0 when it
      # does not, NULL when either argument is NULL.
      def self.call(arguments : Array(Engine::Value)) : Engine::Value
        if arguments.size != ARGUMENT_COUNT
          raise ArgumentError.new("regexp expects #{ARGUMENT_COUNT} arguments, got #{arguments.size}")
        end
        return if arguments.any?(Nil)

        matches?(arguments[0], arguments[1]) ? 1_i64 : 0_i64
      end

      private def self.matches?(pattern_value : Engine::Value, text_value : Engine::Value) : Bool
        Regex.new(text_of(pattern_value)).matches?(text_of(text_value))
      rescue error
        raise ArgumentError.new("regexp: #{error.message || error.class.name}")
      end

      # Reads a non-NULL argument as UTF-8 text, as SQLite's `sqlite3_value_text`
      # would: numbers as their decimal text, a blob's bytes as they are.
      private def self.text_of(value : Engine::Value) : String
        text =
          case value
          when String then value
          when Bytes  then String.new(value)
          else             value.to_s
          end
        raise ArgumentError.new("argument is not valid UTF-8") unless text.valid_encoding?
        text
      end
    end
  end
end
