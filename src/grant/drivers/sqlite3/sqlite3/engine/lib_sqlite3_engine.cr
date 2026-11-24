# Left out of a program built with -Dgrant_without_libsqlite3, which runs
# every statement on Grant's own engine and links no C SQLite library.
{% unless flag?(:grant_without_libsqlite3) %}
  require "../engine"
  require "../lib_sqlite3"

  module Grant::SQLite3
    # The C library behind the engine interface. Every `LibSQLite3` call the
    # driver makes is here; outside it, only `Grant::SQLiteVersionCheck` calls
    # the library.
    class Engine::LibSQLite3Engine < Engine
      def open(filename : String) : {Int32, Engine::Database}
        code = LibSQLite3.open_v2(filename, out handle, (Flag::READWRITE | Flag::CREATE), nil)
        {code, Database.new(handle)}
      end

      class Database < Engine::Database
        # Boxed user-function blocks, kept here so the garbage collector does
        # not free a block SQLite still calls.
        @list_of_user_functions = [] of Pointer(Void)

        def initialize(@handle : LibSQLite3::SQLite3)
        end

        def exec(sql : String) : Int32
          LibSQLite3.exec(@handle, sql, nil, nil, nil)
        end

        def prepare(sql : String) : {Int32, Engine::PreparedStatement}
          code = LibSQLite3.prepare_v2(@handle, sql, sql.bytesize + 1, out statement, nil)
          {code, PreparedStatement.new(statement)}
        end

        def changes : Int64
          LibSQLite3.changes(@handle).to_i64
        end

        def last_insert_rowid : Int64
          LibSQLite3.last_insert_rowid(@handle)
        end

        def error_code : Int32
          LibSQLite3.errcode(@handle)
        end

        def error_message : String
          String.new(LibSQLite3.errmsg(@handle))
        end

        def create_function(name : String, argument_count : Int32, &block : Engine::UserFunction) : Int32
          boxed_block = Box.box(block)
          @list_of_user_functions << boxed_block
          # 1 is the code for UTF-8.
          LibSQLite3.create_function(@handle, name, argument_count, 1, boxed_block, USER_FUNCTION_CALLBACK, nil, nil)
        end

        def backup_to(target : Engine::Database) : Int32
          return backup_through_file_to(target) unless target.is_a?(Database)
          Database.copy_main(from: @handle, to: target.@handle)
        end

        def backup_to_file(path : String) : Int32
          code = LibSQLite3.open_v2(path, out file_handle, (Flag::READWRITE | Flag::CREATE), nil)
          begin
            return code unless code == Engine::OK_CODE
            Database.copy_main(from: @handle, to: file_handle)
          ensure
            LibSQLite3.close(file_handle)
          end
        end

        def restore_from_file(path : String) : Int32
          code = LibSQLite3.open_v2(path, out file_handle, (Flag::READWRITE | Flag::CREATE), nil)
          begin
            return code unless code == Engine::OK_CODE
            Database.copy_main(from: file_handle, to: @handle)
          ensure
            LibSQLite3.close(file_handle)
          end
        end

        # sqlite3_backup_init, one sqlite3_backup_step over every page, and
        # sqlite3_backup_finish, which reports the step's failure and leaves
        # its message on the *to* handle.
        protected def self.copy_main(*, from source : LibSQLite3::SQLite3, to target : LibSQLite3::SQLite3) : Int32
          backup = LibSQLite3.backup_init(target, "main", source, "main")
          return LibSQLite3.errcode(target) if backup.null?
          LibSQLite3.backup_step(backup, -1)
          LibSQLite3.backup_finish(backup).value
        end

        def close : Int32
          LibSQLite3.close(@handle)
        end

        # SQLite calls this from C for every user-function call; it hands all the
        # work to `.call_user_function`, which never lets an exception unwind into
        # SQLite.
        USER_FUNCTION_CALLBACK = ->(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*) do
          Database.call_user_function(context, argc, argv)
          nil
        end

        # :nodoc:
        #
        # Runs the block registered for *context* over the call's arguments and
        # reports its value. An exception the block raises becomes the call's SQL
        # error, carrying the exception's message.
        def self.call_user_function(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*) : Nil
          block = Box(Engine::UserFunction).unbox(LibSQLite3.user_data(context))
          arguments = Array(Engine::Value).new(argc) { |index| value_of(argv[index]) }
          report_result(context, block.call(arguments))
        rescue error
          message = error.message || error.class.name
          LibSQLite3.result_error(context, message, message.bytesize)
        end

        # Reads one function argument. The byte count bounds text and blobs, so
        # text holding a NUL byte is read whole.
        private def self.value_of(value : LibSQLite3::SQLite3Value) : Engine::Value
          case LibSQLite3.value_type(value)
          when Type::INTEGER
            LibSQLite3.value_int64(value)
          when Type::FLOAT
            LibSQLite3.value_double(value)
          when Type::TEXT
            byte_count = LibSQLite3.value_bytes(value)
            pointer = LibSQLite3.value_text(value)
            return "" if pointer.null? || byte_count == 0
            String.new(pointer, byte_count)
          when Type::BLOB
            byte_count = LibSQLite3.value_bytes(value)
            pointer = LibSQLite3.value_blob(value)
            return Bytes.empty if pointer.null? || byte_count == 0
            blob = Bytes.new(byte_count)
            blob.copy_from(pointer, byte_count)
            blob
          else
            nil
          end
        end

        private def self.report_result(context : LibSQLite3::SQLite3Context, result : Engine::Value) : Nil
          case result
          when Nil
            LibSQLite3.result_null(context)
          when Int64
            LibSQLite3.result_int64(context, result)
          when Float64
            LibSQLite3.result_double(context, result)
          when String
            LibSQLite3.result_text(context, result, result.bytesize, TRANSIENT_DESTRUCTOR)
          when Bytes
            LibSQLite3.result_blob(context, result, result.size, TRANSIENT_DESTRUCTOR)
          end
        end

        # SQLITE_TRANSIENT, the destructor value that makes SQLite copy a result.
        TRANSIENT_DESTRUCTOR = Pointer(Void).new(-1.to_u64!)
      end

      class PreparedStatement < Engine::PreparedStatement
        def initialize(@handle : LibSQLite3::Statement)
        end

        def bind_null(index : Int32) : Int32
          LibSQLite3.bind_null(@handle, index)
        end

        def bind_int64(index : Int32, value : Int64) : Int32
          LibSQLite3.bind_int64(@handle, index, value)
        end

        def bind_double(index : Int32, value : Float64) : Int32
          LibSQLite3.bind_double(@handle, index, value)
        end

        def bind_text(index : Int32, value : String) : Int32
          LibSQLite3.bind_text(@handle, index, value, value.bytesize, nil)
        end

        def bind_blob(index : Int32, value : Bytes) : Int32
          LibSQLite3.bind_blob(@handle, index, value, value.size, nil)
        end

        def clear_bindings : Int32
          LibSQLite3.clear_bindings(@handle)
        end

        def step : Int32
          LibSQLite3.step(@handle)
        end

        def column_count : Int32
          LibSQLite3.column_count(@handle)
        end

        def column_name(index : Int32) : String
          String.new(LibSQLite3.column_name(@handle, index))
        end

        def column_type(index : Int32) : Type
          LibSQLite3.column_type(@handle, index)
        end

        def column_int64(index : Int32) : Int64
          LibSQLite3.column_int64(@handle, index)
        end

        def column_double(index : Int32) : Float64
          LibSQLite3.column_double(@handle, index)
        end

        def column_text(index : Int32) : String
          String.new(LibSQLite3.column_text(@handle, index))
        end

        def column_blob(index : Int32) : Bytes
          blob = LibSQLite3.column_blob(@handle, index)
          byte_count = LibSQLite3.column_bytes(@handle, index)
          pointer = Pointer(UInt8).malloc(byte_count)
          pointer.copy_from(blob, byte_count)
          Bytes.new(pointer, byte_count)
        end

        def reset : Int32
          LibSQLite3.reset(@handle)
        end

        def finalize_statement : Int32
          LibSQLite3.finalize(@handle)
        end
      end
    end
  end
{% end %}
