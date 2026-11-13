require "./type"

module Grant
  # `symbol_prefix` starts with byte 1, LLVM's marker for a symbol that is written
  # to the object file exactly as given, so the prefix also carries the underscore
  # that macOS adds to C names. The binding links the same C functions as the
  # public `sqlite3` shard under a different compiler-level name, which lets an app
  # compile both copies; Crystal compares `fun` declarations by that name and
  # refuses two signatures that name different Crystal types.
  {% begin %}
  {% symbol_prefix = flag?(:darwin) ? "\u0001_" : "\u0001" %}
  @[Link("sqlite3")]
    {% if flag?(:msvc) %}
      @[Link(dll: "sqlite3.dll")]
    {% end %}
    lib LibSQLite3
      type SQLite3 = Void*
      type Statement = Void*
      type SQLite3Backup = Void*
      type SQLite3Context = Void*
      type SQLite3Value = Void*
  
      enum Code
        # Successful result
        OKAY = 0
        # Generic error
        ERROR = 1
        # Internal logic error in SQLite
        INTERNAL = 2
        # Access permission denied
        PERM = 3
        # Callback routine requested an abort
        ABORT = 4
        # The database file is locked
        BUSY = 5
        # A table in the database is locked
        LOCKED = 6
        # A malloc() failed
        NOMEM = 7
        # Attempt to write a readonly database
        READONLY = 8
        # Operation terminated by sqlite3_interrupt()
        INTERRUPT = 9
        # Some kind of disk I/O error occurred
        IOERR = 10
        # The database disk image is malformed
        CORRUPT = 11
        # Unknown opcode in sqlite3_file_control()
        NOTFOUND = 12
        # Insertion failed because database is full
        FULL = 13
        # Unable to open the database file
        CANTOPEN = 14
        # Database lock protocol error
        PROTOCOL = 15
        # Internal use only
        EMPTY = 16
        # The database schema changed
        SCHEMA = 17
        # String or BLOB exceeds size limit
        TOOBIG = 18
        # Abort due to constraint violation
        CONSTRAINT = 19
        # Data type mismatch
        MISMATCH = 20
        # Library used incorrectly
        MISUSE = 21
        # Uses OS features not supported on host
        NOLFS = 22
        # Authorization denied
        AUTH = 23
        # Not used
        FORMAT = 24
        # 2nd parameter to sqlite3_bind out of range
        RANGE = 25
        # File opened that is not a database file
        NOTADB = 26
        # Notifications from sqlite3_log()
        NOTICE = 27
        # Warnings from sqlite3_log()
        WARNING = 28
        # sqlite3_step() has another row ready
        ROW = 100
        # sqlite3_step() has finished executing
        DONE = 101
      end
  
      alias Callback = (Void*, Int32, UInt8**, UInt8**) -> Int32
      alias FuncCallback = (SQLite3Context, Int32, SQLite3Value*) -> Void
  
      fun open_v2 = {{ symbol_prefix + "sqlite3_open_v2" }}(filename : UInt8*, db : SQLite3*, flags : ::Grant::SQLite3::Flag, zVfs : UInt8*) : Int32
  
      fun errcode = {{ symbol_prefix + "sqlite3_errcode" }}(SQLite3) : Int32
      fun errmsg = {{ symbol_prefix + "sqlite3_errmsg" }}(SQLite3) : UInt8*
  
      fun backup_init = {{ symbol_prefix + "sqlite3_backup_init" }}(SQLite3, UInt8*, SQLite3, UInt8*) : SQLite3Backup
      fun backup_step = {{ symbol_prefix + "sqlite3_backup_step" }}(SQLite3Backup, Int32) : Code
      fun backup_finish = {{ symbol_prefix + "sqlite3_backup_finish" }}(SQLite3Backup) : Code
  
      fun prepare_v2 = {{ symbol_prefix + "sqlite3_prepare_v2" }}(db : SQLite3, zSql : UInt8*, nByte : Int32, ppStmt : Statement*, pzTail : UInt8**) : Int32
      fun exec = {{ symbol_prefix + "sqlite3_exec" }}(db : SQLite3, zSql : UInt8*, pCallback : Callback, pCallbackArgs : Void*, pzErrMsg : UInt8**) : Int32
      fun step = {{ symbol_prefix + "sqlite3_step" }}(stmt : Statement) : Int32
      fun column_count = {{ symbol_prefix + "sqlite3_column_count" }}(stmt : Statement) : Int32
      fun column_type = {{ symbol_prefix + "sqlite3_column_type" }}(stmt : Statement, iCol : Int32) : ::Grant::SQLite3::Type
      fun column_int64 = {{ symbol_prefix + "sqlite3_column_int64" }}(stmt : Statement, iCol : Int32) : Int64
      fun column_double = {{ symbol_prefix + "sqlite3_column_double" }}(stmt : Statement, iCol : Int32) : Float64
      fun column_text = {{ symbol_prefix + "sqlite3_column_text" }}(stmt : Statement, iCol : Int32) : UInt8*
      fun column_bytes = {{ symbol_prefix + "sqlite3_column_bytes" }}(stmt : Statement, iCol : Int32) : Int32
      fun column_blob = {{ symbol_prefix + "sqlite3_column_blob" }}(stmt : Statement, iCol : Int32) : UInt8*
  
      fun bind_int = {{ symbol_prefix + "sqlite3_bind_int" }}(stmt : Statement, idx : Int32, value : Int32) : Int32
      fun bind_int64 = {{ symbol_prefix + "sqlite3_bind_int64" }}(stmt : Statement, idx : Int32, value : Int64) : Int32
      fun bind_text = {{ symbol_prefix + "sqlite3_bind_text" }}(stmt : Statement, idx : Int32, value : UInt8*, bytes : Int32, destructor : Void* ->) : Int32
      fun bind_blob = {{ symbol_prefix + "sqlite3_bind_blob" }}(stmt : Statement, idx : Int32, value : UInt8*, bytes : Int32, destructor : Void* ->) : Int32
      fun bind_null = {{ symbol_prefix + "sqlite3_bind_null" }}(stmt : Statement, idx : Int32) : Int32
      fun bind_double = {{ symbol_prefix + "sqlite3_bind_double" }}(stmt : Statement, idx : Int32, value : Float64) : Int32
  
      fun bind_parameter_index = {{ symbol_prefix + "sqlite3_bind_parameter_index" }}(stmt : Statement, name : UInt8*) : Int32
      fun reset = {{ symbol_prefix + "sqlite3_reset" }}(stmt : Statement) : Int32
      fun column_name = {{ symbol_prefix + "sqlite3_column_name" }}(stmt : Statement, idx : Int32) : UInt8*
      fun last_insert_rowid = {{ symbol_prefix + "sqlite3_last_insert_rowid" }}(db : SQLite3) : Int64
      fun changes = {{ symbol_prefix + "sqlite3_changes" }}(db : SQLite3) : Int32
  
      fun finalize = {{ symbol_prefix + "sqlite3_finalize" }}(stmt : Statement) : Int32
      fun close_v2 = {{ symbol_prefix + "sqlite3_close_v2" }}(SQLite3) : Int32
      fun close = {{ symbol_prefix + "sqlite3_close" }}(SQLite3) : Int32
  
      fun create_function = {{ symbol_prefix + "sqlite3_create_function" }}(SQLite3, funcName : UInt8*, nArg : Int32, eTextRep : Int32, pApp : Void*, xFunc : FuncCallback, xStep : Void*, xFinal : Void*) : Int32
      fun value_text = {{ symbol_prefix + "sqlite3_value_text" }}(SQLite3Value) : UInt8*
      fun result_int = {{ symbol_prefix + "sqlite3_result_int" }}(SQLite3Context, Int32) : Nil
      fun value_type = {{ symbol_prefix + "sqlite3_value_type" }}(SQLite3Value) : ::Grant::SQLite3::Type
      fun value_bytes = {{ symbol_prefix + "sqlite3_value_bytes" }}(SQLite3Value) : Int32
      fun result_null = {{ symbol_prefix + "sqlite3_result_null" }}(SQLite3Context) : Nil
      fun result_error = {{ symbol_prefix + "sqlite3_result_error" }}(SQLite3Context, UInt8*, Int32) : Nil
    end
  {% end %}
end
