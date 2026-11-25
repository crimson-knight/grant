# Type-checks Grant for Windows without linking, the way an app reaches it:
# the SQLite adapter on the C library (which also compiles Grant's own
# engine), the engine's own adapter, PostgreSQL, and a model queried through
# each. CI runs:
#
#   crystal build --no-codegen --target x86_64-windows-msvc scripts/windows_type_check.cr
#
# The engine opens no database file on Windows yet (it uses POSIX locks and
# mmap(2), as os_unix.c does) and raises Grant::SQLiteEngine::UnsupportedPlatform.
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
Grant::SQLiteEngine::PosixFileSystem.new.open("windows_type_check.db")
