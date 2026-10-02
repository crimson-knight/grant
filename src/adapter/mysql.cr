require "./base"
require "../grant/schema/column_info"
require "mysql"
require "./registry"

# crystal-mysql 0.17.0 does not register the protocol JSON type (245), so its
# result-set decoder raises before Grant can normalize the returned text. This
# one type registration is required at driver decode time; the driver exposes no
# adapter-local decoder hook.
# Mysql implementation of the Adapter
class Grant::Adapter::Mysql < Grant::Adapter::Base
  # :nodoc:
  alias Kind = Grant::Adapter::ErrorTranslator::Kind

  QUOTING_CHAR = '`'

  def mysql? : Bool
    true
  end

  # crystal-mysql's unprepared statements take no bind values, and Grant binds
  # every value, so a MySQL pool keeps preparing whatever
  # `prepared_statements:` says.
  def self.supports_unprepared_statements? : Bool
    false
  end

  # crystal-mysql defaults its handshake charset to utf8 (utf8mb3), which
  # cannot bind four-byte Unicode such as emoji into MySQL 8 utf8mb4 columns.
  # Keep an explicit caller setting and use a broadly supported utf8mb4
  # collation when the URL does not provide one.
  def initialize(name : String, url : String)
    MySql::Type.types_by_code[245_u8] = MySql::Type::String
    unless url.matches?(/[?&]encoding=/i)
      separator = url.includes?("?") ? "&" : "?"
      url = "#{url}#{separator}encoding=utf8mb4_general_ci"
    end
    super(name, url)
  end

  module Schema
    TYPES = {
      "AUTO_Int32" => "INT NOT NULL AUTO_INCREMENT",
      "AUTO_Int64" => "BIGINT NOT NULL AUTO_INCREMENT",
      "AUTO_UUID"  => "CHAR(36)",
      "Float64"    => "DOUBLE",
      "UUID"       => "CHAR(36)",
      "Time"       => "TIMESTAMP(6)",
      # Grant stamps timestamps itself; database defaults would override
      # record_timestamps = false and touch: false.
      "created_at" => "TIMESTAMP(6)",
      "updated_at" => "TIMESTAMP(6)",
    }
  end

  # Using TRUNCATE instead of DELETE so the id column resets to 0
  def clear(table_name : String)
    statement = "TRUNCATE #{quote(table_name)}"

    statement = Grant::QueryLogs.append(statement)
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
    statement = Grant::QueryLogs.append(statement)
    elapsed_time = Time.measure do
      open(statement, params) do |conn|
        # The OK packet already carries the generated id; no second query.
        result = conn.exec statement, args: normalize_bind_values(params)
        last_id = result.last_insert_id if lastval
      end
    end

    log statement, elapsed_time, params

    last_id
  end

  # MySQL resolves duplicates through whichever unique key the row violates, so
  # the columns only serve validation and the default update list.
  def unique_index_columns(table_name : String, index_name : String) : Array(String)?
    columns = [] of String
    sql = "SELECT column_name FROM information_schema.statistics " \
          "WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? AND non_unique = 0 " \
          "ORDER BY seq_in_index"
    open(sql) do |db|
      db.query(sql, table_name, index_name) do |rs|
        rs.each { columns << rs.read(String) }
      end
    end
    columns.empty? ? nil : columns
  end

  protected def bulk_conflict_sql(table_name : String, conflict : Grant::Bulk::Conflict, columns : Array(String)) : String
    case conflict.mode
    in .raise?
      ""
    in .skip?
      # A no-op update skips only key conflicts; INSERT IGNORE would also
      # swallow truncation and NOT NULL errors.
      column = quote(columns.first)
      " ON DUPLICATE KEY UPDATE #{column} = #{column}"
    in .update?
      assignments = if guard = conflict.guard_column
                      # ON DUPLICATE KEY has no WHERE, so each assignment keeps
                      # the existing value unless the guard column matches.
                      if conflict.update_sql
                        raise ArgumentError.new("on_duplicate cannot be tenant-guarded on MySQL; use update_only or run inside unscoped")
                      end
                      matches = "#{quote(guard)} = VALUES(#{quote(guard)})"
                      conflict.update_columns.map do |name|
                        "#{quote(name)} = IF(#{matches}, VALUES(#{quote(name)}), #{quote(name)})"
                      end.join(", ")
                    else
                      bulk_update_assignments(conflict) { |name| "VALUES(#{quote(name)})" }
                    end
      if assignments.empty?
        column = quote(columns.first)
        " ON DUPLICATE KEY UPDATE #{column} = #{column}"
      else
        " ON DUPLICATE KEY UPDATE #{assignments}"
      end
    end
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
    params = [] of Grant::Columns::Type

    statement = String.build do |stmt|
      stmt << "INSERT"
      stmt << " IGNORE" if options["ignore_on_duplicate"]?
      stmt << " INTO #{quote(table_name)} ("
      stmt << fields.map { |field| quote(field) }.join(", ")
      stmt << ") VALUES "

      model_array.each do |model|
        model.set_timestamps
        stmt << "("
        stmt << Array.new(fields.size, '?').join(',')
        params.concat fields.map { |field| model.read_attribute field }
        stmt << "),"
      end
    end.chomp(',')

    if options["update_on_duplicate"]?
      if columns = options["columns"]?
        statement += " ON DUPLICATE KEY UPDATE "
        columns << "updated_at" if fields.includes? "updated_at"
        columns.each do |key|
          statement += "#{quote(key)}=VALUES(#{quote(key)}), "
        end
        statement = statement.chomp(", ")
      end
    end

    statement = Grant::QueryLogs.append(statement)
    elapsed_time = Time.measure do
      open(statement, params) do |db|
        db.exec statement, args: normalize_bind_values(params)
      end
    end

    log statement, elapsed_time, params
  end

  # This will update a row in the database.
  def update(table_name : String, primary_name : String, fields, params)
    statement = String.build do |stmt|
      stmt << "UPDATE #{quote(table_name)} SET "
      stmt << fields.map { |name| "#{quote(name)}=?" }.join(", ")
      stmt << " WHERE #{quote(primary_name)}=?"
    end

    statement = Grant::QueryLogs.append(statement)
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

    statement = Grant::QueryLogs.append(statement)
    elapsed_time = Time.measure do
      open(statement, [value]) do |db|
        db.exec statement, normalize_bind_value(value)
      end
    end

    log statement, elapsed_time, value
  end

  # Grant stores MySQL UUID columns as CHAR(36), while crystal-mysql's UUID
  # parameter encoder sends the 16-byte binary representation. Bind the
  # canonical string used by this adapter's schema instead.
  def normalize_bind_value(value : UUID) : String
    value.to_s
  end

  protected def bind_value_needs_normalization?(value) : Bool
    value.is_a?(UUID) || super
  end

  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    case mode
    when .update?, .share?, .update_no_wait?, .update_skip_locked?
      true
    else
      false
    end
  end

  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    true
  end

  def supports_savepoints? : Bool
    true
  end

  # MySQL uses `LOCK IN SHARE MODE` for shared locks and does not support
  # the SHARE NOWAIT / SHARE SKIP LOCKED variants — those raise, matching
  # the prior behavior of `LockMode#mysql_sql`.
  def lock_clause(mode : Grant::Locking::LockMode) : String
    case mode
    when .update?             then "FOR UPDATE"
    when .share?              then "LOCK IN SHARE MODE"
    when .update_no_wait?     then "FOR UPDATE NOWAIT"
    when .update_skip_locked? then "FOR UPDATE SKIP LOCKED"
    else
      raise Grant::Locking::LockNotAvailableError.new("Lock mode #{mode} not supported in MySQL")
    end
  end

  def adapter_name : String
    "MySQL"
  end

  # Raises `Grant::ConnectionNotEstablished` when the connection URL selected
  # no database, where MySQL's `DATABASE()` returns NULL.
  def current_database : String
    selected = open { |db| db.scalar("SELECT DATABASE()").as?(String) }
    selected || raise Grant::ConnectionNotEstablished.new("No database is selected on the #{name} MySQL connection")
  end

  # True when the server banner names MariaDB, whose version numbers and
  # feature set differ from MySQL's.
  def mariadb? : Bool
    database_version
    @mariadb
  end

  # Records whether the server is MariaDB without querying it, for tooling
  # that pins `#database_version` offline.
  def mariadb=(value : Bool) : Bool
    @mariadb = value
  end

  @mariadb = false

  protected def fetch_database_version : Grant::ServerVersion
    banner = open { |db| db.scalar("SELECT VERSION()").as(String) }
    @mariadb = banner.includes?("MariaDB")
    Grant::ServerVersion.parse(banner)
  end

  def supports_insert_returning? : Bool
    mariadb? && database_version.at_least?(10, 5)
  end

  def supports_insert_on_duplicate_skip? : Bool
    true
  end

  def supports_insert_on_duplicate_update? : Bool
    true
  end

  def supports_foreign_keys? : Bool
    true
  end

  def supports_views? : Bool
    true
  end

  # MySQL 8.0.13 added functional key parts; MariaDB has no expression indexes.
  def supports_expression_index? : Bool
    !mariadb? && database_version.at_least?(8, 0, 13)
  end

  # Enforced from MySQL 8.0.16 and MariaDB 10.2.1.
  def supports_check_constraints? : Bool
    mariadb? ? database_version.at_least?(10, 2, 1) : database_version.at_least?(8, 0, 16)
  end

  def supports_datetime_with_precision? : Bool
    mariadb? ? database_version.at_least?(5, 3) : database_version.at_least?(5, 6, 4)
  end

  def supports_json? : Bool
    mariadb? ? database_version.at_least?(10, 2, 7) : database_version.at_least?(5, 7, 8)
  end

  def supports_common_table_expressions? : Bool
    mariadb? ? database_version.at_least?(10, 2, 1) : database_version.at_least?(8, 0, 1)
  end

  def supports_virtual_columns? : Bool
    mariadb? ? database_version.at_least?(10, 2) : database_version.at_least?(5, 7, 6)
  end

  def supports_comments? : Bool
    true
  end

  def supports_explain? : Bool
    true
  end

  # Optimizer hint comments (`/*+ ... */`) are MySQL only, from 5.7.7.
  def supports_optimizer_hints? : Bool
    !mariadb? && database_version.at_least?(5, 7, 7)
  end

  def supports_advisory_locks? : Bool
    true
  end

  def supports_bulk_alter? : Bool
    true
  end

  def supports_concurrent_connections? : Bool
    true
  end

  def supports_restart_db_transaction? : Bool
    true
  end

  def supports_disable_referential_integrity? : Bool
    true
  end

  # crystal-mysql reports a server error as a `PacketError` that keeps the
  # server's message but drops the numeric error code. The server's English
  # message prefixes are fixed per error, so they stand in for the code until
  # the driver exposes it. Returns nil for messages Grant does not translate.
  def self.errno_for_message(message : String?) : Int32?
    return unless message

    if message.starts_with?("Duplicate entry")
      1062
    elsif message.starts_with?("Cannot add or update a child row")
      1452
    elsif message.starts_with?("Cannot delete or update a parent row")
      1451
    elsif message.starts_with?("Column '") && message.includes?("' cannot be null")
      1048
    elsif message.starts_with?("Field '") && message.includes?("' doesn't have a default value")
      1364
    elsif message.starts_with?("Data too long for column")
      1406
    elsif message.starts_with?("Deadlock found when trying to get lock")
      1213
    elsif message.starts_with?("Lock wait timeout exceeded")
      1205
    elsif message.starts_with?("Statement aborted because lock(s) could not be acquired immediately")
      3572
    elsif message.starts_with?("Query execution was interrupted, maximum statement execution time exceeded")
      3024
    elsif message.starts_with?("Query execution was interrupted")
      1317
    elsif message.starts_with?("Cannot execute statement in a READ ONLY transaction")
      1792
    elsif message.starts_with?("Unknown database")
      1049
    end
  end

  # Classifies a MySQL server error number, or returns nil for numbers Grant
  # does not translate.
  def self.error_kind(errno : Int32?) : Kind?
    case errno
    when 1062, 1586 then Kind::Unique
    when 1451, 1452 then Kind::ForeignKey
    when 1048, 1364 then Kind::NotNull
    when 1406       then Kind::ValueTooLong
    when 1213       then Kind::Deadlock
    when 1205, 3572 then Kind::LockWaitTimeout
    when 3024       then Kind::StatementTimeout
    when 1317       then Kind::QueryCanceled
    when 1290, 1792 then Kind::ReadOnly
    when 1049       then Kind::NoDatabase
    end
  end

  def translate_exception(ex : ::Exception, sql : String? = nil, binds = nil) : ::Exception
    if ex.is_a?(MySql::Connection::PacketError)
      if kind = Mysql.error_kind(Mysql.errno_for_message(ex.message))
        return Grant::Adapter::ErrorTranslator.build(kind, ex.message, sql, binds, ex)
      end
      return Grant::StatementInvalid.new(ex.message, sql, binds, ex)
    end

    super
  end

  # MySQL reports affected rows directly on the exec result.
  def rows_affected_for_optimistic_lock(db, result : DB::ExecResult) : Int64
    result.rows_affected
  end

  # MySQL supports the full set of index hints.
  def supports_index_hints? : Bool
    true
  end

  # `USE INDEX (a, b)` / `FORCE INDEX (a)` / `IGNORE INDEX (a)`.
  def index_hint_clause(kind : Symbol, index_names : Array(String)) : String?
    return if index_names.empty?
    keyword = case kind
              when :use    then "USE INDEX"
              when :force  then "FORCE INDEX"
              when :ignore then "IGNORE INDEX"
              else
                return
              end
    "#{keyword} (#{index_names.map { |n| quote(n) }.join(", ")})"
  end

  # Catalog queries read `information_schema` for *namespace* (a database name)
  # or, without one, the connection's selected database, one statement per kind
  # of catalog data. CAST(... AS CHAR) keeps
  # every text column a String regardless of the server's column collation, and
  # CAST(... AS SIGNED) keeps every flag and position an Int64 (MySQL 9 returns
  # comparisons and unsigned columns as narrower integer types).
  def catalog_tables(namespace : String? = nil) : Array(String)
    names = [] of String
    catalog_query(<<-SQL, [namespace.as(DB::Any)]) { |rs| names << rs.read(String) }
      SELECT CAST(TABLE_NAME AS CHAR) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND TABLE_TYPE = 'BASE TABLE'
      ORDER BY TABLE_NAME
      SQL
    names
  end

  def catalog_columns(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ColumnInfo)
    filter = table ? "AND c.TABLE_NAME = ?" : ""
    sql = <<-SQL
      SELECT CAST(c.TABLE_NAME AS CHAR), CAST(c.COLUMN_NAME AS CHAR), CAST(c.COLUMN_TYPE AS CHAR),
             CAST(c.IS_NULLABLE = 'YES' AS SIGNED), CAST(c.COLUMN_DEFAULT AS CHAR), CAST(COALESCE(s.SEQ_IN_INDEX, 0) AS SIGNED),
             CAST(c.EXTRA LIKE '%auto_increment%' AS SIGNED), CAST(c.ORDINAL_POSITION AS SIGNED), CAST(c.COLUMN_COMMENT AS CHAR),
             CAST(c.EXTRA LIKE '%DEFAULT_GENERATED%' AS SIGNED)
      FROM information_schema.COLUMNS c
      LEFT JOIN information_schema.STATISTICS s
        ON s.TABLE_SCHEMA = c.TABLE_SCHEMA AND s.TABLE_NAME = c.TABLE_NAME
       AND s.COLUMN_NAME = c.COLUMN_NAME AND s.INDEX_NAME = 'PRIMARY'
      WHERE c.TABLE_SCHEMA = COALESCE(?, DATABASE()) #{filter}
      ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
      SQL
    args = [namespace.as(DB::Any)]
    args << table if table

    maria = mariadb?
    columns = [] of Grant::Schema::ColumnInfo
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      name = rs.read(String)
      type = rs.read(String)
      nullable = rs.read(Int64) != 0
      default = rs.read(String?)
      key_position = rs.read(Int64).to_i
      auto = rs.read(Int64) != 0
      position = rs.read(Int64).to_i
      comment = rs.read(String?)
      generated = rs.read(Int64) != 0
      # MariaDB reports "no default" as the text NULL.
      default = nil if maria && default == "NULL"
      default = default_as_sql(default, type, generated) unless maria
      columns << Grant::Schema::ColumnInfo.new(table_name, name, type, nullable, default,
        key_position, auto, position, comment.presence)
    end
    columns
  end

  # MySQL reports a literal default as bare text (`active`, `1`) and an
  # expression default (`DEFAULT_GENERATED` in EXTRA, such as
  # `CURRENT_TIMESTAMP(6)`) as its text. `ColumnInfo#default` is a SQL
  # expression, so a string or temporal literal comes back quoted.
  private def default_as_sql(default : String?, type : String, generated : Bool) : String?
    return default if default.nil? || generated
    return default if Grant::Schema::TypeFamily.classify(type).in?(Grant::Schema::TypeFamily::Integer, Grant::Schema::TypeFamily::Float, Grant::Schema::TypeFamily::Decimal, Grant::Schema::TypeFamily::Boolean)
    Grant::Schema::Dialect::Mysql.quote_literal(default)
  end

  def catalog_indexes(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::IndexInfo)
    filter = table ? "AND TABLE_NAME = ?" : ""
    sql = <<-SQL
      SELECT CAST(TABLE_NAME AS CHAR), CAST(INDEX_NAME AS CHAR), CAST(NON_UNIQUE AS SIGNED), CAST(COLUMN_NAME AS CHAR),
             #{mariadb? ? "NULL" : "CAST(EXPRESSION AS CHAR)"}
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = COALESCE(?, DATABASE()) AND INDEX_NAME <> 'PRIMARY' #{filter}
      ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
      SQL
    args = [namespace.as(DB::Any)]
    args << table if table

    indexes = [] of Grant::Schema::IndexInfo
    current = nil.as({String, String, Bool, Array(String), Bool}?)
    flush = -> {
      if entry = current
        indexes << Grant::Schema::IndexInfo.new(entry[0], entry[1], entry[3], entry[2], nil, entry[4])
      end
    }
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      index_name = rs.read(String)
      unique = rs.read(Int64) == 0
      column = rs.read(String?)
      key_expression = rs.read(String?)
      # Functional key parts have no column name; MySQL 8 reports their expression.
      expression = column.nil?
      if (entry = current) && entry[0] == table_name && entry[1] == index_name
        entry[3] << (column || key_expression || "(expression)")
        current = {entry[0], entry[1], entry[2], entry[3], entry[4] || expression}
      else
        flush.call
        current = {table_name, index_name, unique, [column || key_expression || "(expression)"], expression}
      end
    end
    flush.call
    indexes
  end

  def catalog_foreign_keys(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ForeignKeyInfo)
    filter = table ? "AND k.TABLE_NAME = ?" : ""
    sql = <<-SQL
      SELECT CAST(k.TABLE_NAME AS CHAR), CAST(k.CONSTRAINT_NAME AS CHAR), CAST(k.REFERENCED_TABLE_NAME AS CHAR),
             CAST(k.COLUMN_NAME AS CHAR), CAST(k.REFERENCED_COLUMN_NAME AS CHAR),
             CAST(r.UPDATE_RULE AS CHAR), CAST(r.DELETE_RULE AS CHAR)
      FROM information_schema.KEY_COLUMN_USAGE k
      JOIN information_schema.REFERENTIAL_CONSTRAINTS r
        ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
       AND r.TABLE_NAME = k.TABLE_NAME
      WHERE k.TABLE_SCHEMA = COALESCE(?, DATABASE()) AND k.REFERENCED_TABLE_NAME IS NOT NULL #{filter}
      ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
      SQL
    args = [namespace.as(DB::Any)]
    args << table if table

    keys = [] of Grant::Schema::ForeignKeyInfo
    current = nil.as({String, String, String, Array(String), Array(String), String, String}?)
    flush = -> {
      if entry = current
        keys << Grant::Schema::ForeignKeyInfo.new(entry[0], entry[1], entry[3], entry[2], entry[4],
          Grant::Schema::ReferentialAction.parse(entry[5]), Grant::Schema::ReferentialAction.parse(entry[6]))
      end
    }
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      name = rs.read(String)
      to_table = rs.read(String)
      from = rs.read(String)
      to = rs.read(String)
      on_update = rs.read(String)
      on_delete = rs.read(String)
      if (entry = current) && entry[0] == table_name && entry[1] == name
        entry[3] << from
        entry[4] << to
      else
        flush.call
        current = {table_name, name, to_table, [from], [to], on_update, on_delete}
      end
    end
    flush.call
    keys
  end
end

require "./mysql_test_helpers"

Grant::Adapter::Registry.register(Grant::Adapter::Mysql, "mysql", "mysql2")
