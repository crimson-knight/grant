require "../engine"
require "../../../../sqlite_engine"

module Grant::SQLite3
  # Grant's pure-Crystal engine behind the engine interface. It opens the
  # database file with `Grant::SQLiteEngine` and runs SELECT statements with
  # `Grant::SQLiteEngine::Query`; other statements arrive with milestone G4b,
  # and until then preparing or executing one raises
  # `Grant::SQLiteEngine::UnsupportedSQL`.
  class Engine::GrantEngine < Engine
    MEMORY_FILENAME = ":memory:"

    # Opens *filename* like SQLite's READWRITE | CREATE open: a missing file
    # is created empty, and `":memory:"` (or an empty name) gives an empty
    # in-memory database.
    def open(filename : String) : {Int32, Engine::Database}
      if filename.empty? || filename == MEMORY_FILENAME
        engine_database = SQLiteEngine::Database.from_bytes(Bytes.empty)
      else
        File.touch(filename) unless File.exists?(filename)
        engine_database = SQLiteEngine::Database.open(filename)
      end
      {Engine::OK_CODE, Database.new(engine_database)}
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
        SQLiteEngine::SQL::Parser.parse_all(sql).each do |statement|
          text = statement.to_sql
          code, prepared = prepare(text)
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

      def prepare(sql : String) : {Int32, Engine::PreparedStatement}
        query = @session.prepare(sql)
        succeed
        {Engine::OK_CODE, PreparedStatement.new(self, query).as(Engine::PreparedStatement)}
      rescue error : SQLiteEngine::SQLError
        {fail(error.result_code, error.message || "SQL error"), FailedStatement.new.as(Engine::PreparedStatement)}
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

      def backup_to(target : Engine::Database) : Int32
        raise SQLiteEngine::UnsupportedSQL.new("database backup in Grant's SQLite engine arrives with milestone G4b")
      end

      def close : Int32
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

      def step : Int32
        @last_code = @query.step ? Engine::ROW_CODE : Engine::DONE_CODE
        @database.succeed
        @last_code
      rescue error : SQLiteEngine::SQLError
        @last_code = @database.fail(error.result_code, error.message || "SQL error")
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

      def reset : Int32
        @query.reset
        code = @last_code
        @last_code = Engine::OK_CODE
        code == Engine::ROW_CODE || code == Engine::DONE_CODE ? Engine::OK_CODE : code
      end

      def finalize_statement : Int32
        reset
      end

      private def value(index : Int32) : SQLiteEngine::Value
        @query.row[index]?
      end

      private def bind(index : Int32, value : SQLiteEngine::Value) : Int32
        @query.bind(index, value)
        Engine::OK_CODE
      rescue error : SQLiteEngine::SQLError
        @database.fail(error.result_code, error.message || "bind failed")
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
