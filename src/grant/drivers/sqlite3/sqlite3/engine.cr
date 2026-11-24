require "file_utils"

module Grant::SQLite3
  # The seam between Grant's SQLite driver and the engine that runs its SQL.
  #
  # `Connection`, `Statement` and `ResultSet` call only this interface. The C
  # library is the first implementation (`LibSQLite3Engine`); Grant's own
  # engine (`GrantEngine`) is the second. An app picks one with
  # `Grant.settings.sqlite_engine` in `config/initializers/grant.cr`, and each
  # connection reads that setting when it opens.
  #
  # Methods that can fail return an SQLite result code (0 is OK, 100 a row,
  # 101 done), so the driver keeps one set of close and error rules for every
  # engine; the message for a failed call comes from `Database#error_message`.
  abstract class Engine
    # A value an engine hands to a user function, and the value the function
    # returns.
    alias Value = Nil | Int64 | Float64 | String | Bytes

    # A user function: it receives the argument values and returns the
    # result. An exception it raises becomes an SQL error for the statement
    # that called it, carrying the exception's message.
    alias UserFunction = Array(Value) -> Value

    OK_CODE    =   0
    ERROR_CODE =   1
    ROW_CODE   = 100
    DONE_CODE  = 101

    # Why `:libsqlite3` is refused in a program that left the C engine out.
    LIBSQLITE3_LEFT_OUT = "sqlite_engine :libsqlite3 needs the C SQLite engine: require \"grant/adapter/sqlite\" " \
                          "(or \"grant/adapter/sqlite/libsqlite3\"), in a program built without -Dgrant_without_libsqlite3"

    # Whether this program has the C SQLite engine: it required
    # `grant/adapter/sqlite` (or the driver's `libsqlite3` file) and was not
    # built with -Dgrant_without_libsqlite3. Without it the program links no
    # C SQLite library.
    def self.libsqlite3_compiled_in? : Bool
      {% if Grant::SQLite3::Engine.has_constant?("LibSQLite3Engine") %}
        true
      {% else %}
        false
      {% end %}
    end

    # The engine named *name*: `:libsqlite3` or `:grant`.
    def self.named(name : Symbol) : Engine
      case name
      when :libsqlite3
        {% if Grant::SQLite3::Engine.has_constant?("LibSQLite3Engine") %}
          LibSQLite3Engine.new
        {% else %}
          raise ArgumentError.new(LIBSQLITE3_LEFT_OUT)
        {% end %}
      when :grant then GrantEngine.new
      else
        raise ArgumentError.new("sqlite_engine must be :libsqlite3 or :grant (got #{name.inspect})")
      end
    end

    # The engine `Grant.settings.sqlite_engine` names. When the driver is
    # used without the rest of Grant: the C library if the program has it,
    # otherwise Grant's engine.
    def self.selected : Engine
      {% if Grant.has_constant?(:Settings) %}
        named(Grant.settings.sqlite_engine)
      {% else %}
        {% if Grant::SQLite3::Engine.has_constant?("LibSQLite3Engine") %}
          LibSQLite3Engine.new
        {% else %}
          GrantEngine.new
        {% end %}
      {% end %}
    end

    # Opens the database at *filename* for reading and writing, creating it
    # when it does not exist; `":memory:"` opens a private in-memory
    # database. Returns the result code and the database, which holds the
    # error message when the code is not OK.
    abstract def open(filename : String) : {Int32, Database}

    # An open database.
    abstract class Database
      # Runs *sql*, which may hold several statements and returns no rows
      # (the connection URL's PRAGMA string).
      abstract def exec(sql : String) : Int32

      # Compiles one statement. Returns the result code and the statement.
      abstract def prepare(sql : String) : {Int32, PreparedStatement}

      # Rows changed by the most recent INSERT, UPDATE or DELETE.
      abstract def changes : Int64

      abstract def last_insert_rowid : Int64

      # The result code of the most recent failed call.
      abstract def error_code : Int32

      # The message of the most recent failed call.
      abstract def error_message : String

      # Registers *name* as an SQL function of *argument_count* arguments,
      # evaluated by the block.
      abstract def create_function(name : String, argument_count : Int32, &block : UserFunction) : Int32

      # Copies this database's main schema over *target*'s. A code other than
      # OK means the copy failed and *target* holds the message.
      abstract def backup_to(target : Database) : Int32

      # Writes a copy of this database's main schema to the database file
      # at *path*, replacing what the file holds.
      abstract def backup_to_file(path : String) : Int32

      # Copies the database file at *path* over this database's main
      # schema. A code other than OK means the copy failed and this database
      # holds the message.
      abstract def restore_from_file(path : String) : Int32

      # Copies this database over *target* by way of a database file in a
      # new temporary directory: how a database of one engine is copied over
      # a database of the other.
      protected def backup_through_file_to(target : Database) : Int32
        directory = File.tempname("grant-sqlite-backup")
        Dir.mkdir(directory, 0o700)
        begin
          path = File.join(directory, "copy.db")
          code = backup_to_file(path)
          return code unless code == OK_CODE
          target.restore_from_file(path)
        ensure
          FileUtils.rm_rf(directory)
        end
      end

      abstract def close : Int32
    end

    # A compiled statement. Parameters are numbered from 1, columns from 0.
    abstract class PreparedStatement
      abstract def bind_null(index : Int32) : Int32
      abstract def bind_int64(index : Int32, value : Int64) : Int32
      abstract def bind_double(index : Int32, value : Float64) : Int32

      # Binds *value* without copying it; the caller keeps it alive until the
      # statement is reset or finalized.
      abstract def bind_text(index : Int32, value : String) : Int32

      # Binds *value* without copying it; the caller keeps it alive until the
      # statement is reset or finalized.
      abstract def bind_blob(index : Int32, value : Bytes) : Int32

      abstract def clear_bindings : Int32

      # Runs the statement to its next row: `ROW_CODE` with a row ready,
      # `DONE_CODE` when finished, any other code on failure.
      abstract def step : Int32

      abstract def column_count : Int32
      abstract def column_name(index : Int32) : String
      abstract def column_type(index : Int32) : Type
      abstract def column_int64(index : Int32) : Int64
      abstract def column_double(index : Int32) : Float64
      abstract def column_text(index : Int32) : String
      abstract def column_blob(index : Int32) : Bytes

      # Returns the statement to its start. Returns the code of the most
      # recent step when that step failed.
      abstract def reset : Int32

      # Frees the statement whatever it returns, so it is called once.
      # Returns the code of the most recent step when that step failed. (Not
      # named `finalize`: Crystal's garbage collector calls a method of that
      # name, which would free the statement a second time.)
      abstract def finalize_statement : Int32
    end
  end
end
