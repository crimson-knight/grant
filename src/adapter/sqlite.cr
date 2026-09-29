require "./base"
require "sqlite3"
require "../grant/sqlite_version_check"
require "../grant/schema/column_info"

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
  # :nodoc:
  alias Kind = Grant::Adapter::ErrorTranslator::Kind

  QUOTING_CHAR = '"'

  def sqlite? : Bool
    true
  end

  # SQLite stores Grant timestamps as text and UUID columns as CHAR(36).
  def normalize_bind_value(value : Time) : String
    value.in(SQLite3::TIME_ZONE).to_s("%F %H:%M:%S.%6N")
  end

  def normalize_bind_value(value : UUID) : String
    value.to_s
  end

  def read_time(result : DB::ResultSet) : Time
    text = result.read(String)
    parse_time(text)
  end

  def read_nullable_time(result : DB::ResultSet) : Time?
    result.read(String?).try { |text| parse_time(text) }
  end

  private def parse_time(text : String) : Time
    format = text.includes?(".") ? "%F %H:%M:%S.%N" : SQLite3::DATE_FORMAT_SECOND
    Time.parse(text, format, location: SQLite3::TIME_ZONE)
  end

  # PRAGMAs applied to every connection unless the URL or `pragmas` says
  # otherwise. Foreign keys are enforced (SQLite leaves them off), a busy
  # connection waits five seconds instead of failing at once, and WAL with
  # `synchronous=normal` is the fast, still crash-safe journal mode. WAL needs
  # a local filesystem with shared memory (not a network mount) and writes
  # `-wal` and `-shm` files next to the database that backups must include, so
  # everything except `foreign_keys` is applied only to file databases.
  DEFAULT_PRAGMAS = {
    "foreign_keys" => "1",
    "journal_mode" => "wal",
    "busy_timeout" => "5000",
    "synchronous"  => "normal",
  }

  # Builds the adapter. *pragmas* overrides the defaults for this connection,
  # for example `pragmas: {journal_mode: "delete"}`; a value written in the URL
  # query still wins over both.
  def initialize(name : String, url : String, pragmas : NamedTuple? = nil)
    overrides = {} of String => String
    pragmas.try(&.to_h.each { |key, value| overrides[key.to_s] = value.to_s })
    super(name, Sqlite.url_with_pragmas(url, overrides))
    # Check SQLite version on first connection
    Grant::SQLiteVersionCheck.ensure_supported!
  end

  # Returns *url* with the default PRAGMA parameters and *overrides* appended
  # for every key the URL query does not already set.
  def self.url_with_pragmas(url : String, overrides : Hash(String, String) = {} of String => String) : String
    base, _, query = url.partition('?')
    present = Set(String).new
    query.split('&') do |pair|
      key = pair.partition('=')[0]
      present << key unless key.empty?
    end

    memory = memory_url?(url)
    additions = [] of String
    DEFAULT_PRAGMAS.each do |key, default|
      next if present.includes?(key)
      value = overrides[key]? || ((memory && key != "foreign_keys") ? nil : default)
      additions << "#{key}=#{value}" if value
    end
    overrides.each do |key, value|
      next if present.includes?(key) || DEFAULT_PRAGMAS.has_key?(key)
      additions << "#{key}=#{value}"
    end
    return url if additions.empty?

    query.empty? ? "#{base}?#{additions.join('&')}" : "#{base}?#{query}&#{additions.join('&')}"
  end

  # True for `:memory:` and `mode=memory` databases, which have no file to
  # journal and live only as long as one connection.
  def self.memory_url?(url : String) : Bool
    url.includes?(":memory:") || url.includes?("mode=memory")
  end

  def adapter_name : String
    "SQLite"
  end

  # The database file, or `:memory:`.
  def current_database : String
    file = open { |db| db.scalar("SELECT file FROM pragma_database_list WHERE name = 'main'").as(String) }
    file.empty? ? ":memory:" : file
  end

  # SQLite's version is that of the linked library, so no query is needed.
  protected def fetch_database_version : Grant::ServerVersion
    Grant::ServerVersion.parse(Grant::SQLiteVersionCheck.version_string)
  end

  # `RETURNING` arrived in SQLite 3.35.
  def supports_insert_returning? : Bool
    database_version.at_least?(3, 35)
  end

  def supports_insert_on_duplicate_skip? : Bool
    true
  end

  def supports_insert_on_duplicate_update? : Bool
    true
  end

  def supports_ddl_transactions? : Bool
    true
  end

  def supports_partial_index? : Bool
    true
  end

  def supports_expression_index? : Bool
    true
  end

  def supports_check_constraints? : Bool
    true
  end

  def supports_foreign_keys? : Bool
    true
  end

  def supports_views? : Bool
    true
  end

  def supports_datetime_with_precision? : Bool
    true
  end

  # The JSON functions are built in from SQLite 3.38.
  def supports_json? : Bool
    database_version.at_least?(3, 38)
  end

  def supports_common_table_expressions? : Bool
    true
  end

  # Generated columns arrived in SQLite 3.31.
  def supports_virtual_columns? : Bool
    database_version.at_least?(3, 31)
  end

  def supports_explain? : Bool
    true
  end

  # An in-memory database belongs to a single connection.
  def supports_concurrent_connections? : Bool
    !Sqlite.memory_url?(url)
  end

  def supports_disable_referential_integrity? : Bool
    true
  end

  # SQLite reports the primary result code plus, for constraints, a message
  # that names the constraint type (extended codes are not enabled by the
  # driver). The message prefixes are SQLite's own fixed, untranslated text.
  def self.error_kind(code : Int32?, message : String? = nil) : Kind?
    return nil unless code

    case code
    when 2067, 1555 then return Kind::Unique
    when 787        then return Kind::ForeignKey
    when 1299       then return Kind::NotNull
    end

    case code & 0xFF
    when 5, 6 then Kind::LockWaitTimeout
    when 8    then Kind::ReadOnly
    when 9    then Kind::QueryCanceled
    when 14   then Kind::NoDatabase
    when 18   then Kind::ValueTooLong
    when 19
      if message.nil?
        nil
      elsif message.starts_with?("UNIQUE constraint failed") || message.starts_with?("PRIMARY KEY must be unique")
        Kind::Unique
      elsif message.starts_with?("FOREIGN KEY constraint failed")
        Kind::ForeignKey
      elsif message.starts_with?("NOT NULL constraint failed")
        Kind::NotNull
      end
    end
  end

  def translate_exception(ex : ::Exception, sql : String? = nil, binds = nil) : ::Exception
    if ex.is_a?(SQLite3::Exception)
      if kind = Sqlite.error_kind(ex.code, ex.message)
        return Grant::Adapter::ErrorTranslator.build(kind, ex.message, sql, binds, ex)
      end
      return Grant::StatementInvalid.new(ex.message, sql, binds, ex)
    end

    super
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
      open(statement) do |db|
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
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
        last_id = db.scalar(last_val()).as(Int64) if lastval
      end
    end

    log statement, elapsed_time, params

    last_id
  end

  # SQLite's `sqlite3_bind_parameter` cap since 3.32 is 32,766.
  def bulk_bind_limit : Int32
    32_766
  end

  # Reads the key columns of a plain unique index. Expression indexes have no
  # column name and cannot be an `ON CONFLICT` target, so they raise.
  def unique_index_columns(table_name : String, index_name : String) : Array(String)?
    unique = nil
    partial = false
    open do |db|
      db.query("PRAGMA index_list(#{quote(table_name)})") do |rs|
        rs.each do
          rs.read(Int64)
          name = rs.read(String)
          is_unique = rs.read(Int64) == 1
          rs.read(String)
          is_partial = rs.read(Int64) == 1
          if name == index_name
            unique = is_unique
            partial = is_partial
          end
        end
      end
    end
    return nil if unique.nil?
    raise ArgumentError.new("Index #{index_name.inspect} is not unique") unless unique
    raise ArgumentError.new("Index #{index_name.inspect} is partial; pass the column names to unique_by instead") if partial

    columns = [] of String
    open do |db|
      db.query("PRAGMA index_info(#{quote(index_name)})") do |rs|
        rs.each do
          rs.read(Int64)
          rs.read(Int64)
          column = rs.read(String?)
          raise ArgumentError.new("Index #{index_name.inspect} is an expression index; pass the column names to unique_by instead") unless column
          columns << column
        end
      end
    end
    columns
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
    params = [] of Grant::Columns::Type

    statement = String.build do |stmt|
      if options["update_on_duplicate"]?
        stmt << "INSERT "
      elsif options["ignore_on_duplicate"]?
        stmt << "INSERT OR IGNORE "
      else
        stmt << "INSERT "
      end
      stmt << "INTO #{quote(table_name)} ("
      stmt << fields.map { |field| quote(field) }.join(", ")
      stmt << ") VALUES "

      model_array.each do |model|
        model.set_timestamps
        stmt << '('
        stmt << Array.new(fields.size, '?').join(',')
        params.concat fields.map { |field| model.read_attribute field }
        stmt << "),"
      end
    end.chomp(',')

    if options["update_on_duplicate"]?
      if columns = options["columns"]?
        update_columns = columns.dup
        update_columns << "updated_at" if fields.includes?("updated_at") && !update_columns.includes?("updated_at")
        unless update_columns.empty?
          statement += " ON CONFLICT (#{quote(primary_name)}) DO UPDATE SET "
          statement += update_columns.map { |key| "#{quote(key)} = excluded.#{quote(key)}" }.join(", ")
        end
      end
    end

    elapsed_time = Time.measure do
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
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
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
      end
    end

    log statement, elapsed_time, params
  end

  # This will delete a row from the database.
  def delete(table_name : String, primary_name : String, value)
    statement = "DELETE FROM #{quote(table_name)} WHERE #{quote(primary_name)}=?"

    elapsed_time = Time.measure do
      open(statement, [value]) do |db|
        db.exec statement, normalize_bind_value(value)
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

  # SQLite's DB::ExecResult does not reliably expose the affected-row count.
  def rows_affected_after_write(db, result : DB::ExecResult) : Int64
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

  # SQLite has no information_schema. Every catalog query joins `sqlite_master`
  # with the `pragma_*` table-valued functions, so all tables are answered by
  # one statement per kind instead of one PRAGMA per table. *namespace* is
  # ignored: only the main database is inspected.
  private CATALOG_TABLE_FILTER = "m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\'"

  def catalog_tables(namespace : String? = nil) : Array(String)
    names = [] of String
    catalog_query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name") do |rs|
      names << rs.read(String)
    end
    names
  end

  def catalog_columns(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ColumnInfo)
    sql = String.build do |io|
      io << "SELECT m.name, p.cid, p.name, p.type, p.\"notnull\", p.dflt_value, p.pk "
      io << "FROM sqlite_master m JOIN pragma_table_xinfo(m.name) p "
      io << "WHERE #{CATALOG_TABLE_FILTER} AND p.hidden <> 1"
      io << " AND m.name = ?" if table
      io << " ORDER BY m.name, p.cid"
    end
    args = table ? [table.as(DB::Any)] : [] of DB::Any

    rows = [] of {String, Int32, String, String, Bool, String?, Int32}
    key_size = Hash(String, Int32).new(0)
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      cid = rs.read(Int64).to_i
      name = rs.read(String)
      type = rs.read(String?) || ""
      not_null = rs.read(Int64) != 0
      default = rs.read(String?)
      key_position = rs.read(Int64).to_i
      key_size[table_name] += 1 if key_position > 0
      rows << {table_name, cid, name, type, not_null, default, key_position}
    end

    rows.map do |table_name, cid, name, type, not_null, default, key_position|
      # A lone INTEGER PRIMARY KEY is the rowid alias: it auto-increments and
      # can never be NULL even though PRAGMA reports notnull = 0.
      rowid_alias = key_position == 1 && key_size[table_name] == 1 && type.upcase == "INTEGER"
      Grant::Schema::ColumnInfo.new(table_name, name, type, !(not_null || rowid_alias), default,
        key_position, rowid_alias, cid + 1)
    end
  end

  def catalog_indexes(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::IndexInfo)
    sql = String.build do |io|
      io << "SELECT m.name, il.name, il.\"unique\", il.partial, ii.name, im.sql "
      io << "FROM sqlite_master m JOIN pragma_index_list(m.name) il "
      io << "JOIN pragma_index_xinfo(il.name) ii ON ii.key = 1 "
      io << "LEFT JOIN sqlite_master im ON im.type = 'index' AND im.name = il.name "
      io << "WHERE #{CATALOG_TABLE_FILTER} AND il.origin <> 'pk'"
      io << " AND m.name = ?" if table
      io << " ORDER BY m.name, il.name, ii.seqno"
    end
    args = table ? [table.as(DB::Any)] : [] of DB::Any

    indexes = [] of Grant::Schema::IndexInfo
    current = nil.as({String, String, Bool, String?, Array(String?)}?)
    flush = -> {
      if entry = current
        indexes << sqlite_index_info(*entry)
      end
    }
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      index_name = rs.read(String)
      unique = rs.read(Int64) != 0
      rs.read(Int64) # partial: derived from the CREATE INDEX text below
      column = rs.read(String?)
      create_sql = rs.read(String?)
      if (entry = current) && entry[0] == table_name && entry[1] == index_name
        entry[4] << column
      else
        flush.call
        current = {table_name, index_name, unique, create_sql, [column] of String?}
      end
    end
    flush.call
    indexes
  end

  def catalog_foreign_keys(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ForeignKeyInfo)
    sql = String.build do |io|
      io << "SELECT m.name, fk.id, fk.\"table\", fk.\"from\", fk.\"to\", fk.on_update, fk.on_delete "
      io << "FROM sqlite_master m JOIN pragma_foreign_key_list(m.name) fk "
      io << "WHERE #{CATALOG_TABLE_FILTER}"
      io << " AND m.name = ?" if table
      io << " ORDER BY m.name, fk.id, fk.seq"
    end
    args = table ? [table.as(DB::Any)] : [] of DB::Any

    keys = [] of Grant::Schema::ForeignKeyInfo
    current = nil.as({String, Int64, String, Array(String), Array(String?), String, String}?)
    flush = -> {
      if entry = current
        keys << Grant::Schema::ForeignKeyInfo.new(entry[0], nil, entry[3], entry[2],
          sqlite_referenced_columns(entry[2], entry[4]),
          Grant::Schema::ReferentialAction.parse(entry[5]), Grant::Schema::ReferentialAction.parse(entry[6]))
      end
    }
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      id = rs.read(Int64)
      to_table = rs.read(String)
      from = rs.read(String)
      to = rs.read(String?)
      on_update = rs.read(String)
      on_delete = rs.read(String)
      if (entry = current) && entry[0] == table_name && entry[1] == id
        entry[3] << from
        entry[4] << to
      else
        flush.call
        current = {table_name, id, to_table, [from], [to] of String?, on_update, on_delete}
      end
    end
    flush.call
    keys
  end

  # A key that omits the parent columns refers to the parent's primary key.
  private def sqlite_referenced_columns(parent : String, named : Array(String?)) : Array(String)
    return named.compact if named.none?(&.nil?)
    parent_key = catalog_columns(parent).select(&.primary_key?).sort_by!(&.primary_key_position).map(&.name)
    named.each_with_index.map { |name, index| name || parent_key[index]? || "" }.to_a
  end

  private def sqlite_index_info(table_name : String, index_name : String, unique : Bool,
                                create_sql : String?, columns : Array(String?)) : Grant::Schema::IndexInfo
    expression = columns.any?(&.nil?)
    names = columns
    if expression
      pieces = sqlite_index_pieces(create_sql)
      names = columns.map_with_index { |column, index| column || pieces[index]? || "(expression)" }
    end
    where = create_sql.try { |text| text[/\sWHERE\s+(.*)\z/mi, 1]?.try(&.strip) }
    Grant::Schema::IndexInfo.new(table_name, index_name, names.compact, unique, where, expression)
  end

  # The comma separated entries between the parentheses of a CREATE INDEX.
  private def sqlite_index_pieces(create_sql : String?) : Array(String)
    return [] of String unless create_sql
    start = create_sql.index('(')
    return [] of String unless start
    pieces = [] of String
    depth = 0
    from = start + 1
    create_sql.each_char_with_index do |char, index|
      next if index <= start
      case char
      when '('
        depth += 1
      when ')'
        if depth == 0
          pieces << create_sql[from...index]
          break
        end
        depth -= 1
      when ','
        if depth == 0
          pieces << create_sql[from...index]
          from = index + 1
        end
      end
    end
    pieces.map(&.strip.sub(/\s+(?:ASC|DESC)\z/i, ""))
  end
end
