require "./base"
require "sqlite3"
require "../grant/sqlite_version_check"

# Patch SQLite3::Statement so that perform_exec always calls sqlite3_reset in
# its ensure clause.  SQLite does NOT decrement db->nVdbeActive when
# sqlite3_step returns SQLITE_LOCKED (or similar) unless sqlite3_reset is
# explicitly called.  Without this, a subsequent COMMIT on the same connection
# fails with "cannot commit transaction - SQL statements in progress".
#
# NOTE: this duplicates the upstream method body from sqlite3 ~> 0.21.0
# (src/sqlite3/statement.cr) and adds only the ensure-reset.  When bumping the
# sqlite3 shard, diff upstream perform_exec against this patch and re-apply.
class SQLite3::Statement
  protected def perform_exec(args : Enumerable) : DB::ExecResult
    LibSQLite3.reset(self.to_unsafe)
    args.each_with_index(1) do |arg, index|
      bind_arg(index, arg)
    end

    step = uninitialized LibSQLite3::Code
    loop do
      step = LibSQLite3::Code.new LibSQLite3.step(self)
      break unless step == LibSQLite3::Code::ROW
    end
    raise Exception.new(sqlite3_connection) unless step == LibSQLite3::Code::DONE

    rows_affected = LibSQLite3.changes(sqlite3_connection).to_i64
    last_id = LibSQLite3.last_insert_rowid(sqlite3_connection)
    DB::ExecResult.new rows_affected, last_id
  ensure
    # Always reset the statement so SQLite decrements nVdbeActive even when
    # the step returned an error code.  This prevents "SQL statements in
    # progress" on a subsequent COMMIT/ROLLBACK on the same connection.
    LibSQLite3.reset(self.to_unsafe)
  end
end

# Sqlite implementation of the Adapter
class Grant::Adapter::Sqlite < Grant::Adapter::Base
  QUOTING_CHAR = '"'

  def initialize(@name : String, @url : String)
    super
    # Check SQLite version on first connection
    Grant::SQLiteVersionCheck.ensure_supported!
  end

  module Schema
    TYPES = {
      "AUTO_Int32" => "INTEGER NOT NULL",
      "AUTO_Int64" => "INTEGER NOT NULL",
      "AUTO_UUID"  => "CHAR(36)",
      "UUID"       => "CHAR(36)",
      "Int32"      => "INTEGER",
      "Int64"      => "INTEGER",
      "created_at" => "VARCHAR",
      "updated_at" => "VARCHAR",
    }
  end

  # remove all rows from a table and reset the counter on the id.
  def clear(table_name : String)
    statement = "DELETE FROM #{quote(table_name)}"

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement
      end
    end

    log statement, elapsed_time
  end

  def insert(table_name : String, fields, params, lastval) : Int64
    statement = String.build do |stmt|
      stmt << "INSERT INTO #{quote(table_name)} ("
      stmt << fields.map { |name| "#{quote(name)}" }.join(", ")
      stmt << ") VALUES ("
      stmt << fields.map { |_name| "?" }.join(", ")
      stmt << ")"
    end

    last_id = -1_i64
    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, args: params
        last_id = db.scalar(last_val()).as(Int64) if lastval
      end
    end

    log statement, elapsed_time, params

    last_id
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
    params = [] of Grant::Columns::Type

    statement = String.build do |stmt|
      if options["update_on_duplicate"]?
        # Note: This is legacy code. New code should use upsert_all
        # which properly handles ON CONFLICT for SQLite 3.24+
        stmt << "INSERT OR REPLACE "
      elsif options["ignore_on_duplicate"]?
        stmt << "INSERT OR IGNORE "
      else
        stmt << "INSERT "
      end
      stmt << "INTO #{quote(table_name)} ("
      stmt << fields.map { |field| quote(field) }.join(", ")
      stmt << ") VALUES "

      model_array.each do |model|
        next unless model.valid?
        model.set_timestamps
        stmt << '('
        stmt << Array.new(fields.size, '?').join(',')
        params.concat fields.map { |field| model.read_attribute field }
        stmt << "),"
      end
    end.chomp(',')

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, args: params
      end
    end

    log statement, elapsed_time, params
  end

  private def last_val
    "SELECT LAST_INSERT_ROWID()"
  end

  # This will update a row in the database.
  def update(table_name : String, primary_name : String, fields, params)
    statement = String.build do |stmt|
      stmt << "UPDATE #{quote(table_name)} SET "
      stmt << fields.map { |name| "#{quote(name)}=?" }.join(", ")
      stmt << " WHERE #{quote(primary_name)}=?"
    end

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, args: params
      end
    end

    log statement, elapsed_time, params
  end

  # This will delete a row from the database.
  def delete(table_name : String, primary_name : String, value)
    statement = "DELETE FROM #{quote(table_name)} WHERE #{quote(primary_name)}=?"

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, value
      end
    end

    log statement, elapsed_time, value
  end

  # SQLite recognizes the TRUE/FALSE keywords (3.23+) as aliases for 1/0.
  def quote_boolean(value : Bool) : String
    value ? "TRUE" : "FALSE"
  end

  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    false
  end

  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    false
  end

  def supports_savepoints? : Bool
    true
  end

  # SQLite has no row-level locking, so the lock clause is a no-op (empty
  # string). This preserves the prior `LockMode#sqlite_sql` degradation:
  # locking queries still run, just without an appended lock clause.
  def lock_clause(mode : Grant::Locking::LockMode) : String
    ""
  end

  # SQLite does not report affected rows through `DB::ExecResult` for our
  # optimistic-lock UPDATE, so query `changes()` on the same connection.
  def rows_affected_for_optimistic_lock(db, result : DB::ExecResult) : Int64
    db.scalar("SELECT changes()").as(Int64)
  end

  # SQLite supports `INDEXED BY <name>` (a forced single-index choice). It has
  # no FORCE/IGNORE distinction, so only `:use` is honored — and only a single
  # index. `:force` is treated like `:use` (INDEXED BY *is* a force); `:ignore`
  # has no equivalent and degrades (returns nil).
  def supports_index_hints? : Bool
    true
  end

  def index_hint_clause(kind : Symbol, index_names : Array(String)) : String?
    return nil if index_names.empty?
    case kind
    when :use, :force
      "INDEXED BY #{quote(index_names.first)}"
    else # :ignore — no SQLite equivalent
      nil
    end
  end
end
