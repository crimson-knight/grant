# Grant's own SQLite engine for the driver. A program compiles the engine
# only when it requires this file: `require "grant/adapter/sqlite/grant_engine"`
# does, `require "grant/adapter/sqlite"` (the C library) does not.
require "./sqlite3/engine"
require "../../sqlite_engine"

module Grant::SQLite3
  # Grant's pure-Crystal engine behind the engine interface. It opens the
  # database file read-write with `Grant::SQLiteEngine` and runs every
  # statement with `Grant::SQLiteEngine::Query`. SQL the engine does not
  # implement yet fails with an SQL error naming the construct.
  class Engine::GrantEngine < Engine
    MEMORY_FILENAME = ":memory:"

    # Opens *filename* like SQLite's READWRITE | CREATE open: a missing file
    # is created empty, and `":memory:"` (or an empty name) gives an empty
    # in-memory database.
    def open(filename : String) : {Int32, Engine::Database}
      if filename.empty? || filename == MEMORY_FILENAME
        pager = SQLiteEngine::Pager.open_read_write(SQLiteEngine::MemoryFileSystem.new, MEMORY_FILENAME)
        engine_database = SQLiteEngine::Database.new(pager)
      else
        pager = SQLiteEngine::Pager.open_read_write(SQLiteEngine::PosixFileSystem.new, filename)
        engine_database = SQLiteEngine::Database.new(pager, File.realpath(filename))
      end
      {Engine::OK_CODE, Database.new(engine_database)}
    rescue error : SQLiteEngine::Error | File::Error
      {14, FailedDatabase.new(error.message || "unable to open database file")}
    end

    class Database < Engine::Database
      getter engine_database : SQLiteEngine::Database
      getter session : SQLiteEngine::Query::Session
      getter error_code : Int32 = Engine::OK_CODE
      getter error_message : String = "not an error"

      def initialize(@engine_database : SQLiteEngine::Database)
        @session = SQLiteEngine::Query::Session.new(@engine_database)
      end

      # Runs each statement of *sql*, reading and discarding the rows of a
      # SELECT.
      def exec(sql : String) : Int32
        SQLiteEngine::SQL::Parser.parse_each_prepared(sql).each do |statement|
          code, prepared = prepare(statement.text)
          return code unless code == Engine::OK_CODE
          loop do
            step_code = prepared.step
            break if step_code == Engine::DONE_CODE
            next if step_code == Engine::ROW_CODE
            prepared.finalize_statement
            return step_code
          end
          prepared.finalize_statement
        end
        succeed
      rescue error : SQLiteEngine::SQL::ParseError
        fail(Engine::ERROR_CODE, error.message || "syntax error")
      end

      # Statements that compile without reading the schema: BEGIN, COMMIT,
      # END, ROLLBACK, SAVEPOINT and RELEASE.
      TRANSACTION_CONTROL = %w[BEGIN COMMIT END ROLLBACK SAVEPOINT RELEASE]

      # Whether *sql*'s first word is one of TRANSACTION_CONTROL, read
      # without a regular expression since every prepare asks.
      def self.transaction_control?(sql : String) : Bool
        bytes = sql.to_slice
        start = 0
        while start < bytes.size && bytes[start].unsafe_chr.ascii_whitespace?
          start += 1
        end
        finish = start
        while finish < bytes.size && bytes[finish].unsafe_chr.ascii_letter?
          finish += 1
        end
        return false if finish == start || (finish < bytes.size && (bytes[finish].unsafe_chr.ascii_alphanumeric? || bytes[finish] == 0x5f_u8))
        word = bytes[start, finish - start]
        TRANSACTION_CONTROL.any? do |keyword|
          keyword.bytesize == word.size && (0...word.size).all? { |index| keyword.to_unsafe[index] == word[index] & 0xdf_u8 }
        end
      end

      # Whether *sql* compiles without reading the schema, so preparing it
      # takes no lock: transaction control, and a PRAGMA C compiles without
      # PragFlg_NeedSchema (`PRAGMA busy_timeout` among them, which must
      # succeed while another connection holds a lock).
      def self.compiles_without_the_schema?(sql : String) : Bool
        return true if transaction_control?(sql)
        pragma_name = SQLiteEngine::Query::PragmaFileAccess.name_in(sql)
        return false unless pragma_name
        !SQLiteEngine::Query::PragmaFileAccess.compile_reads_schema?(pragma_name)
      end

      def prepare(sql : String) : {Int32, Engine::PreparedStatement}
        query = if Database.compiles_without_the_schema?(sql)
                  @session.prepare(sql)
                else
                  # Compiling reads the schema only; it leaves the open
                  # transaction's snapshot unpinned, as C does.
                  @session.begin_statement_read(for_transaction: false)
                  begin
                    @session.prepare(sql)
                  ensure
                    @session.end_statement_read
                  end
                end
        succeed
        @open_statement_count += 1
        {Engine::OK_CODE, PreparedStatement.new(self, query).as(Engine::PreparedStatement)}
      rescue error : SQLiteEngine::SQLError
        {fail(error.result_code, error.message || "SQL error"), FailedStatement.new.as(Engine::PreparedStatement)}
      rescue error : SQLiteEngine::Error
        {fail(Engine::ERROR_CODE, error.message || "SQL error"), FailedStatement.new.as(Engine::PreparedStatement)}
      end

      def changes : Int64
        @session.changes
      end

      def last_insert_rowid : Int64
        @session.last_insert_rowid
      end

      def create_function(name : String, argument_count : Int32, &block : Engine::UserFunction) : Int32
        @session.register_function(name, argument_count) { |arguments| block.call(arguments) }
        Engine::OK_CODE
      end

      # Copies this database's pages over *target*'s main schema as one
      # transaction on *target* (sqlite3_backup_init, _step(-1) and _finish):
      # the same schema, rows, sqlite_sequence, user_version and
      # application_id. A failure is a result code, with the message on
      # *target*.
      def backup_to(target : Engine::Database) : Int32
        return backup_through_file_to(target) unless target.is_a?(Database)
        target.restore_from(@session.database.pager)
      end

      def backup_to_file(path : String) : Int32
        code, file_database = GrantEngine.new.open(path)
        return fail(code, file_database.error_message) unless file_database.is_a?(Database)
        begin
          code = file_database.restore_from(@session.database.pager)
          code == Engine::OK_CODE ? succeed : fail(code, file_database.error_message)
        ensure
          file_database.close
        end
      end

      def restore_from_file(path : String) : Int32
        source = SQLiteEngine::Database.open(path)
        begin
          restore_from(source.pager)
        ensure
          source.close
        end
      rescue error : SQLiteEngine::Error | File::Error
        fail_with(error)
      end

      # :nodoc:
      protected def restore_from(source : SQLiteEngine::Pager) : Int32
        SQLiteEngine::Query::Backup.copy(source, @session)
        succeed
      rescue error : SQLiteEngine::Error | File::Error
        fail_with(error)
      end

      BUSY_CODE        =  5
      READ_ONLY_CODE   =  8
      CORRUPT_CODE     = 11
      CANNOT_OPEN_CODE = 14
      # SQLITE_READONLY_DIRECTORY: the folder takes no journal file.
      READ_ONLY_DIRECTORY_CODE = 1544

      # Records *error* as C reports it: the result code and its message.
      private def fail_with(error : ::Exception) : Int32
        if error.is_a?(SQLiteEngine::SQLError)
          fail(error.result_code, error.message || "SQL error")
        elsif error.is_a?(SQLiteEngine::Busy)
          fail(BUSY_CODE, "database is locked")
        elsif error.is_a?(SQLiteEngine::ReadOnlyDatabase)
          fail(READ_ONLY_CODE, "attempt to write a readonly database")
        elsif error.is_a?(SQLiteEngine::CorruptDatabase)
          fail(CORRUPT_CODE, "database disk image is malformed")
        elsif error.is_a?(File::AccessDeniedError)
          fail(READ_ONLY_DIRECTORY_CODE, "attempt to write a readonly database")
        elsif error.is_a?(File::Error)
          fail(CANNOT_OPEN_CODE, "unable to open database file")
        else
          fail(Engine::ERROR_CODE, error.message || "SQL error")
        end
      end

      # Statements prepared and not yet finalized.
      @open_statement_count = 0

      # :nodoc:
      protected def statement_finalized : Nil
        @open_statement_count -= 1
      end

      # sqlite3_close: refused while a statement is unfinalized.
      def close : Int32
        if @open_statement_count > 0
          return fail(5, "unable to close due to unfinalized statements or unfinished backups")
        end
        @engine_database.close
        Engine::OK_CODE
      end

      # :nodoc:
      protected def succeed : Int32
        @error_code = Engine::OK_CODE
        @error_message = "not an error"
        Engine::OK_CODE
      end

      # :nodoc:
      protected def fail(code : Int32, message : String) : Int32
        @error_code = code
        @error_message = message
        code
      end
    end

    # A SELECT compiled by `Grant::SQLiteEngine::Query`, read a row at a
    # time. Column reads convert the value the way sqlite3_column_* does.
    class PreparedStatement < Engine::PreparedStatement
      @last_code = Engine::OK_CODE

      def initialize(@database : Database, @query : SQLiteEngine::Query::PreparedQuery)
      end

      def bind_null(index : Int32) : Int32
        bind(index, nil)
      end

      def bind_int64(index : Int32, value : Int64) : Int32
        bind(index, value)
      end

      def bind_double(index : Int32, value : Float64) : Int32
        bind(index, value)
      end

      def bind_text(index : Int32, value : String) : Int32
        bind(index, value)
      end

      def bind_blob(index : Int32, value : Bytes) : Int32
        bind(index, value)
      end

      def clear_bindings : Int32
        @query.clear_bindings
        Engine::OK_CODE
      end

      # True from the first step until the statement finishes or resets:
      # the session holds a SHARED lock for it meanwhile.
      @reading = false

      def step : Int32
        if !@reading && @query.reads_database?
          @database.session.begin_statement_read
          @reading = true
        end
        @last_code = @query.step ? Engine::ROW_CODE : Engine::DONE_CODE
        finish_reading unless @last_code == Engine::ROW_CODE
        @database.succeed
        @last_code
      rescue error : SQLiteEngine::SQLError
        finish_reading
        @last_code = @database.fail(error.result_code, error.message || "SQL error")
      rescue error : SQLiteEngine::Error
        finish_reading
        @last_code = @database.fail(Engine::ERROR_CODE, error.message || "SQL error")
      end

      private def finish_reading : Nil
        return unless @reading
        @reading = false
        @database.session.end_statement_read
      end

      def column_count : Int32
        @query.column_count
      end

      def column_name(index : Int32) : String
        @query.list_of_column_names[index]
      end

      def column_type(index : Int32) : Type
        case value(index)
        when Int64   then Type::INTEGER
        when Float64 then Type::FLOAT
        when String  then Type::TEXT
        when Bytes   then Type::BLOB
        else              Type::NULL
        end
      end

      def column_int64(index : Int32) : Int64
        SQLiteEngine::Query::ValueSemantics.integer_value(value(index))
      end

      def column_double(index : Int32) : Float64
        SQLiteEngine::Query::ValueSemantics.real_value(value(index))
      end

      def column_text(index : Int32) : String
        SQLiteEngine::Query::ValueSemantics.text(value(index)) || ""
      end

      def column_blob(index : Int32) : Bytes
        SQLiteEngine::Query::ValueSemantics.blob(value(index)) || Bytes.empty
      end

      # A reset ends the statement, committing an autocommit write whose
      # RETURNING rows were not all read; its failure is the reset's result,
      # as sqlite3_reset reports it.
      def reset : Int32
        @query.reset
        finish_reading
        begin
          @database.session.finish_pending_commit
        rescue error : SQLiteEngine::SQLError
          @last_code = Engine::OK_CODE
          return @database.fail(error.result_code, error.message || "SQL error")
        end
        code = @last_code
        @last_code = Engine::OK_CODE
        code == Engine::ROW_CODE || code == Engine::DONE_CODE ? Engine::OK_CODE : code
      end

      @finalized = false

      def finalize_statement : Int32
        code = reset
        unless @finalized
          @finalized = true
          @database.statement_finalized
        end
        code
      end

      private def value(index : Int32) : SQLiteEngine::Value
        @query.row[index]?
      end

      # :nodoc:
      def bind_value(index : Int32, value : SQLiteEngine::Value) : Int32
        bind(index, value)
      end

      private def bind(index : Int32, value : SQLiteEngine::Value) : Int32
        @query.bind(index, value)
        Engine::OK_CODE
      rescue error : SQLiteEngine::SQLError
        @database.fail(error.result_code, error.message || "bind failed")
      end
    end

    # What `open` hands back when the file could not be opened: every call
    # fails with the open's message.
    class FailedDatabase < Engine::Database
      getter error_code : Int32 = 14
      getter error_message : String

      def initialize(@error_message : String)
      end

      def exec(sql : String) : Int32
        @error_code
      end

      def prepare(sql : String) : {Int32, Engine::PreparedStatement}
        {@error_code, FailedStatement.new.as(Engine::PreparedStatement)}
      end

      def changes : Int64
        0_i64
      end

      def last_insert_rowid : Int64
        0_i64
      end

      def create_function(name : String, argument_count : Int32, &block : Engine::UserFunction) : Int32
        @error_code
      end

      def backup_to(target : Engine::Database) : Int32
        @error_code
      end

      def backup_to_file(path : String) : Int32
        @error_code
      end

      def restore_from_file(path : String) : Int32
        @error_code
      end

      def close : Int32
        Engine::OK_CODE
      end
    end

    # What `prepare` hands back when compiling failed: every call reports
    # the failure the database already holds.
    class FailedStatement < Engine::PreparedStatement
      def bind_null(index : Int32) : Int32
        Engine::ERROR_CODE
      end

      def bind_int64(index : Int32, value : Int64) : Int32
        Engine::ERROR_CODE
      end

      def bind_double(index : Int32, value : Float64) : Int32
        Engine::ERROR_CODE
      end

      def bind_text(index : Int32, value : String) : Int32
        Engine::ERROR_CODE
      end

      def bind_blob(index : Int32, value : Bytes) : Int32
        Engine::ERROR_CODE
      end

      def clear_bindings : Int32
        Engine::OK_CODE
      end

      def step : Int32
        Engine::ERROR_CODE
      end

      def column_count : Int32
        0
      end

      def column_name(index : Int32) : String
        ""
      end

      def column_type(index : Int32) : Type
        Type::NULL
      end

      def column_int64(index : Int32) : Int64
        0_i64
      end

      def column_double(index : Int32) : Float64
        0.0
      end

      def column_text(index : Int32) : String
        ""
      end

      def column_blob(index : Int32) : Bytes
        Bytes.empty
      end

      def reset : Int32
        Engine::OK_CODE
      end

      def finalize_statement : Int32
        Engine::OK_CODE
      end
    end
  end
end
