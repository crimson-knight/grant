# Type-checks Grant for Windows without linking, the way an app reaches it:
# the SQLite adapter on the C library (which also compiles Grant's own
# engine), the engine's own adapter, PostgreSQL, and a model queried through
# each. CI runs:
#
#   crystal build --no-codegen --target x86_64-windows-msvc scripts/windows_type_check.cr
#
# On Windows the engine opens files through WindowsFileSystem (os_win.c's
# LockFileEx locks and file-mapped wal-index); the windows-engine job runs it.
require "../src/grant"
require "../src/adapter/sqlite"
require "../src/adapter/sqlite/grant_engine"
require "../src/adapter/pg"

Grant::ConnectionRegistry.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Sqlite,
  url: "sqlite3:./windows_type_check.db",
)
Grant::ConnectionRegistry.establish_connection(
  database: "postgres",
  adapter: Grant::Adapter::Pg,
  url: "postgres://localhost/windows_type_check",
)

class WindowsTypeCheckPost < Grant::Base
  connection primary
  table posts

  column id : Int64, primary: true
  column title : String
end

WindowsTypeCheckPost.where(title: "x").first?
WindowsTypeCheckPost.create(title: "x")
Grant::SQLiteEngine::FileSystem.native.open("windows_type_check.db").close
Grant::SQLiteEngine::FileSystem.native.open_shared_memory("windows_type_check.db-shm").close(delete: true)
