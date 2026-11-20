# Declared as nested modules so this file loads whether or not the SQLite
# adapter is required.
module Grant
  module SQLite3
    # :nodoc:
    #
    # The `regexp(pattern, text)` SQL function, which SQLite runs for
    # `text REGEXP pattern`. It is opt-in: once `require "grant/regex"` defines this
    # module, every Grant SQLite connection registers it. It follows SQLite's conventions for
    # extension functions: a NULL argument gives NULL, and a bad pattern or bad text
    # reports an error through `sqlite3_result_error`, which the calling query then
    # raises as a `Grant::SQLite3::Exception` on the fiber that ran it.
    module RegexpFunction
      ARGUMENT_COUNT = 2

      # SQLite calls this from C for every `REGEXP` it evaluates, so it hands all
      # work to `.call`, which never lets an exception unwind into SQLite.
      CALLBACK = ->(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*) do
        call(context, argc, argv)
        nil
      end

      # Evaluates one call. SQLite invokes it from C, so every Crystal exception
      # stops here and becomes an SQL error result.
      def self.call(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*) : Nil
        if argc != ARGUMENT_COUNT
          report_error(context, "regexp expects #{ARGUMENT_COUNT} arguments, got #{argc}")
          return
        end

        arguments = Slice.new(argv, argc)
        if arguments.any? { |value| LibSQLite3.value_type(value).null? }
          LibSQLite3.result_null(context)
          return
        end

        pattern = text_of(arguments[0])
        text = text_of(arguments[1])
        matched = Regex.new(pattern).matches?(text)
        LibSQLite3.result_int(context, matched ? 1 : 0)
      rescue ex
        report_error(context, "regexp: #{ex.message || ex.class.name}")
      end

      # Reads a non-NULL argument as UTF-8 text. The byte count bounds the read, so
      # text holding a NUL byte is read whole.
      private def self.text_of(value : LibSQLite3::SQLite3Value) : String
        pointer = LibSQLite3.value_text(value)
        byte_count = LibSQLite3.value_bytes(value)
        return "" if pointer.null? || byte_count == 0

        text = String.new(pointer, byte_count)
        raise ArgumentError.new("argument is not valid UTF-8") unless text.valid_encoding?
        text
      end

      private def self.report_error(context : LibSQLite3::SQLite3Context, message : String) : Nil
        LibSQLite3.result_error(context, message, message.bytesize)
      end
    end
  end
end
