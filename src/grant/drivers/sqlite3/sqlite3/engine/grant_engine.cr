require "../engine"
require "../../../../sqlite_engine"

module Grant::SQLite3
  # Grant's pure-Crystal engine behind the engine interface. It opens the
  # database file with `Grant::SQLiteEngine`; running SQL arrives with
  # milestone G4, so until then preparing or executing a statement raises
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

      # User functions registered on this connection, by name, for G4 to call.
      getter user_functions = {} of String => Engine::UserFunction

      def initialize(@engine_database : SQLiteEngine::Database)
      end

      def exec(sql : String) : Int32
        raise GrantEngine.unsupported_statement(sql)
      end

      def prepare(sql : String) : {Int32, Engine::PreparedStatement}
        raise GrantEngine.unsupported_statement(sql)
      end

      def changes : Int64
        0_i64
      end

      def last_insert_rowid : Int64
        0_i64
      end

      def error_code : Int32
        Engine::OK_CODE
      end

      def error_message : String
        "not an error"
      end

      def create_function(name : String, argument_count : Int32, &block : Engine::UserFunction) : Int32
        @user_functions[name] = block
        Engine::OK_CODE
      end

      def backup_to(target : Engine::Database) : Int32
        raise SQLiteEngine::UnsupportedSQL.new("database backup in Grant's SQLite engine arrives with milestone G4")
      end

      def close : Int32
        @engine_database.close
        Engine::OK_CODE
      end
    end

    # :nodoc:
    def self.unsupported_statement(sql : String) : SQLiteEngine::UnsupportedSQL
      SQLiteEngine::UnsupportedSQL.new("running SQL in Grant's SQLite engine arrives with milestone G4: #{sql}")
    end
  end
end
