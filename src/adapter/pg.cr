require "pg"
require "./base"
require "../grant/schema/column_info"
require "./registry"

# PostgreSQL implementation of the Adapter
class Grant::Adapter::Pg < Grant::Adapter::Base
  QUOTING_CHAR = '"'

  def postgres? : Bool
    true
  end

  # Normalize PostgreSQL-specific values after the driver has decoded them.
  # Numeric and geometric values use strings to preserve their exact text;
  # arrays use the driver's text representation when their element types are
  # outside Grant's core result union.
  def normalize_result_value(value) : Grant::Result::Value
    return Grant::Result.normalize(value) if value.is_a?(Grant::Result::Value)

    case value
    when JSON::PullParser
      JSON::Any.new(value)
    when PG::Numeric, PG::Geo::Point, PG::Geo::Line, PG::Geo::Circle,
         PG::Geo::LineSegment, PG::Geo::Box, PG::Geo::Path, PG::Geo::Polygon,
         PG::Interval, Array
      value.to_s
    else
      Grant::Result.normalize(value)
    end
  end

  module Schema
    TYPES = {
      "Float32"        => "REAL",
      "Float64"        => "DOUBLE PRECISION",
      "String"         => "TEXT",
      "AUTO_Int32"     => "SERIAL",
      "AUTO_Int64"     => "BIGSERIAL",
      "AUTO_UUID"      => "UUID",
      "UUID"           => "UUID",
      "created_at"     => "TIMESTAMP",
      "updated_at"     => "TIMESTAMP",
      "Array(String)"  => "TEXT[]",
      "Array(Int16)"   => "SMALLINT[]",
      "Array(Int32)"   => "INT[]",
      "Array(Int64)"   => "BIGINT[]",
      "Array(Float32)" => "REAL[]",
      "Array(Float64)" => "DOUBLE PRECISION[]",
      "Array(Bool)"    => "BOOLEAN[]",
      "Array(UUID)"    => "UUID[]",
    }
  end

  # remove all rows from a table and reset the counter on the id.
  def clear(table_name : String)
    statement = "DELETE FROM #{quote(table_name)}"

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
      stmt << position_str(fields.size)
      stmt << ")"

      stmt << " RETURNING #{quote(lastval)}" if lastval
    end

    last_id = -1_i64
    statement = Grant::QueryLogs.append(statement)
    elapsed_time = Time.measure do
      open(statement, params) do |db|
        if lastval
          last_id = db.scalar(statement, args: normalize_bind_values(params)).as(Int32 | Int64).to_i64
        else
          db.exec statement, args: normalize_bind_values(params)
        end
      end
    end

    log statement, elapsed_time, params

    last_id
  end

  def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)
    params = [] of Grant::Columns::Type
    # PG fails when inserting null into AUTO INCREMENT PK field.
    # If AUTO INCREMENT is TRUE AND all model's pk are nil, remove PK from fields list for AUTO INCREMENT to work properly
    fields.reject! { |field| field == primary_name } if model_array.all? { |m| m.to_h[primary_name].nil? } && auto
    index = 0

    statement = String.build do |stmt|
      stmt << "INSERT"
      stmt << " INTO #{quote(table_name)} ("
      stmt << fields.map { |field| quote(field) }.join(", ")
      stmt << ") VALUES "

      model_array.each do |model|
        model.set_timestamps
        stmt << '('
        stmt << fields.map_with_index { |_f, idx| "$#{index + idx + 1}" }.join(',')
        params.concat fields.map { |field| model.read_attribute field }
        stmt << "),"
        index += fields.size
      end
    end.chomp(',')

    if options["update_on_duplicate"]?
      if columns = options["columns"]?
        statement += " ON CONFLICT (#{quote(primary_name)}) DO UPDATE SET "
        columns << "updated_at" if fields.includes? "updated_at"
        columns.each do |key|
          statement += "#{quote(key)}=EXCLUDED.#{quote(key)}, "
        end
      end
      statement = statement.chomp(", ")
    elsif options["ignore_on_duplicate"]?
      statement += " ON CONFLICT DO NOTHING"
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
      stmt << fields.map_with_index { |name, i| "#{quote(name)}=$#{i + 1}" }.join(", ")
      stmt << " WHERE #{quote(primary_name)}=$#{fields.size + 1}"
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
    statement = "DELETE FROM #{quote(table_name)} WHERE #{quote(primary_name)}=$1"

    statement = Grant::QueryLogs.append(statement)
    elapsed_time = Time.measure do
      open(statement, [value]) do |db|
        db.exec statement, value
      end
    end

    log statement, elapsed_time, value
  end

  # PostgreSQL accepts SQL-standard boolean literals.
  def quote_boolean(value : Bool) : String
    value ? "TRUE" : "FALSE"
  end

  # The server accepts 65,535 parameters, but crystal-pg writes the Bind
  # message's parameter count as a signed 16-bit integer and raises halfway
  # through the message above 32,767, which leaves the connection unusable.
  def bulk_bind_limit : Int32
    32_767
  end

  # Reads the key columns of a plain unique index. Partial and expression
  # indexes cannot be named by `ON CONFLICT (columns)`, so they raise.
  def unique_index_columns(table_name : String, index_name : String) : Array(String)?
    sql = <<-SQL
      SELECT i.indisunique, i.indpred IS NOT NULL, i.indexprs IS NOT NULL,
             ARRAY(SELECT a.attname::text
                     FROM unnest(i.indkey::int2[]) WITH ORDINALITY k(attnum, ord)
                     JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                    ORDER BY k.ord)
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
       WHERE c.relname = $1 AND i.indrelid = $2::regclass
      SQL
    found = nil
    open(sql) do |db|
      db.query(sql, index_name, quote(table_name)) do |rs|
        rs.each do
          unique = rs.read(Bool)
          partial = rs.read(Bool)
          expression = rs.read(Bool)
          columns = rs.read(Array(String))
          raise ArgumentError.new("Index #{index_name.inspect} is not unique") unless unique
          raise ArgumentError.new("Index #{index_name.inspect} is partial or an expression index; pass the column names to unique_by instead") if partial || expression
          found = columns
        end
      end
    end
    found
  end

  def ensure_clause_template(clause : String, starting_index : Int32 = 0) : String
    Grant::Adapter::PlaceholderScanner.rewrite(clause, starting_index, numbered: true)
  end

  def parameter_placeholder(index : Int32) : String
    "$#{index}"
  end

  private def position_str(n : Int32) : String
    i = 1
    String.build do |str|
      while i <= n
        str << "$" << i
        i += 1
        str << ", " if i <= n
      end
    end
  end

  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    true
  end

  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    true
  end

  def supports_savepoints? : Bool
    true
  end

  # PostgreSQL supports the full set of row-level lock clauses.
  def lock_clause(mode : Grant::Locking::LockMode) : String
    case mode
    when .update?             then "FOR UPDATE"
    when .share?              then "FOR SHARE"
    when .update_no_wait?     then "FOR UPDATE NOWAIT"
    when .update_skip_locked? then "FOR UPDATE SKIP LOCKED"
    when .share_no_wait?      then "FOR SHARE NOWAIT"
    when .share_skip_locked?  then "FOR SHARE SKIP LOCKED"
    else
      mode.to_s
    end
  end

  def adapter_name : String
    "PostgreSQL"
  end

  def current_database : String
    open { |db| db.scalar("SELECT current_database()").as(String) }
  end

  # `server_version_num` is major * 10000 + minor for PostgreSQL 10 and later.
  protected def fetch_database_version : Grant::ServerVersion
    number = open { |db| db.scalar("SHOW server_version_num").as(String).to_i }
    Grant::ServerVersion.new(number // 10_000, number % 10_000)
  end

  def supports_insert_returning? : Bool
    true
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

  def supports_json? : Bool
    true
  end

  def supports_common_table_expressions? : Bool
    true
  end

  # Stored generated columns arrived in PostgreSQL 12.
  def supports_virtual_columns? : Bool
    database_version.at_least?(12)
  end

  def supports_comments? : Bool
    true
  end

  def supports_explain? : Bool
    true
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

  # `UNIQUE NULLS NOT DISTINCT` arrived in PostgreSQL 15.
  def supports_nulls_not_distinct? : Bool
    database_version.at_least?(15)
  end

  # Classifies a server error by SQLSTATE. `57014` covers both a user cancel and
  # `statement_timeout`; the server's message is the only thing that tells them
  # apart, so it is consulted for that one code.
  def self.error_kind(sqlstate : String?, message : String? = nil) : Grant::Adapter::ErrorTranslator::Kind?
    return nil unless sqlstate
    kind = Grant::Adapter::ErrorTranslator.kind_for_sqlstate(sqlstate)
    if kind.try(&.query_canceled?) && message.try(&.includes?("statement timeout"))
      return Grant::Adapter::ErrorTranslator::Kind::StatementTimeout
    end
    kind
  end

  # A connect-time `3D000` (invalid_catalog_name): the database does not exist.
  protected def connect_failure_kind(ex : ::DB::ConnectionRefused) : Grant::Adapter::ErrorTranslator::Kind?
    cause = ex.cause
    return nil unless cause.is_a?(PQ::PQError)

    Pg.error_kind(cause.field_message(:code), cause.message)
  end

  def translate_exception(ex : ::Exception, sql : String? = nil, binds = nil) : ::Exception
    if ex.is_a?(PQ::PQError)
      if kind = Pg.error_kind(ex.field_message(:code), ex.message)
        return Grant::Adapter::ErrorTranslator.build(kind, ex.message, sql, binds, ex)
      end
      return Grant::StatementInvalid.new(ex.message, sql, binds, ex)
    end

    super
  end

  # PostgreSQL reports affected rows directly on the exec result.
  def rows_affected_for_optimistic_lock(db, result : DB::ExecResult) : Int64
    result.rows_affected
  end

  # The catalog queries read `pg_catalog` directly and inspect one schema:
  # *namespace* when given, otherwise the connection's `current_schema()`.
  def catalog_tables(namespace : String? = nil) : Array(String)
    names = [] of String
    catalog_query(<<-SQL, [namespace.as(DB::Any)]) { |rs| names << rs.read(String) }
      SELECT c.relname::text FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = COALESCE($1::text, current_schema()) AND c.relkind IN ('r', 'p')
      ORDER BY c.relname
      SQL
    names
  end

  private def pg_catalog_args(table : String?, namespace : String?) : Array(DB::Any)
    args = [namespace.as(DB::Any)]
    args << table if table
    args
  end

  def catalog_columns(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ColumnInfo)
    filter = table ? "AND c.relname = $2" : ""
    sql = <<-SQL
      SELECT c.relname::text, a.attname::text, format_type(a.atttypid, a.atttypmod),
             NOT a.attnotnull, pg_get_expr(d.adbin, d.adrelid),
             -- indkey is 0-based, so the array position is one behind the key position
             COALESCE(array_position(i.indkey::int2[], a.attnum) + 1, 0)::int,
             (a.attidentity IN ('a', 'd') OR COALESCE(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false)),
             a.attnum::int, col_description(c.oid, a.attnum)
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
      LEFT JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
      WHERE n.nspname = COALESCE($1::text, current_schema()) AND c.relkind IN ('r', 'p')
        AND a.attnum > 0 AND NOT a.attisdropped #{filter}
      ORDER BY c.relname, a.attnum
      SQL
    args = pg_catalog_args(table, namespace)

    columns = [] of Grant::Schema::ColumnInfo
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      name = rs.read(String)
      type = rs.read(String)
      nullable = rs.read(Bool)
      default = rs.read(String?)
      key_position = rs.read(Int32)
      auto = rs.read(Bool)
      position = rs.read(Int32)
      comment = rs.read(String?)
      columns << Grant::Schema::ColumnInfo.new(table_name, name, type, nullable, default,
        key_position, auto, position, comment)
    end
    columns
  end

  def catalog_indexes(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::IndexInfo)
    filter = table ? "AND t.relname = $2" : ""
    sql = <<-SQL
      SELECT t.relname::text, i.relname::text, ix.indisunique,
             pg_get_expr(ix.indpred, ix.indrelid),
             COALESCE(a.attname::text, pg_get_indexdef(ix.indexrelid, k.ord::int, true)),
             (k.attnum = 0)
      FROM pg_index ix
      JOIN pg_class i ON i.oid = ix.indexrelid
      JOIN pg_class t ON t.oid = ix.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      CROSS JOIN LATERAL unnest(ix.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
      LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
      WHERE n.nspname = COALESCE($1::text, current_schema()) AND NOT ix.indisprimary
        AND k.ord <= ix.indnkeyatts #{filter}
      ORDER BY t.relname, i.relname, k.ord
      SQL
    args = pg_catalog_args(table, namespace)

    indexes = [] of Grant::Schema::IndexInfo
    current = nil.as({String, String, Bool, String?, Array(String), Bool}?)
    flush = -> {
      if entry = current
        indexes << Grant::Schema::IndexInfo.new(entry[0], entry[1], entry[4], entry[2], entry[3], entry[5])
      end
    }
    catalog_query(sql, args) do |rs|
      table_name = rs.read(String)
      index_name = rs.read(String)
      unique = rs.read(Bool)
      where = rs.read(String?)
      column = rs.read(String)
      expression = rs.read(Bool)
      if (entry = current) && entry[0] == table_name && entry[1] == index_name
        entry[4] << column
        current = {entry[0], entry[1], entry[2], entry[3], entry[4], entry[5] || expression}
      else
        flush.call
        current = {table_name, index_name, unique, where, [column], expression}
      end
    end
    flush.call
    indexes
  end

  def catalog_foreign_keys(table : String? = nil, namespace : String? = nil) : Array(Grant::Schema::ForeignKeyInfo)
    filter = table ? "AND t.relname = $2" : ""
    sql = <<-SQL
      SELECT t.relname::text, c.conname::text, ft.relname::text, a.attname::text, fa.attname::text,
             c.confupdtype::text, c.confdeltype::text
      FROM pg_constraint c
      JOIN pg_class t ON t.oid = c.conrelid
      JOIN pg_class ft ON ft.oid = c.confrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      CROSS JOIN LATERAL unnest(c.conkey, c.confkey) WITH ORDINALITY AS k(local_attnum, foreign_attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.local_attnum
      JOIN pg_attribute fa ON fa.attrelid = c.confrelid AND fa.attnum = k.foreign_attnum
      WHERE c.contype = 'f' AND n.nspname = COALESCE($1::text, current_schema()) #{filter}
      ORDER BY t.relname, c.conname, k.ord
      SQL
    args = pg_catalog_args(table, namespace)

    keys = [] of Grant::Schema::ForeignKeyInfo
    current = nil.as({String, String, String, Array(String), Array(String), String, String}?)
    flush = -> {
      if entry = current
        keys << Grant::Schema::ForeignKeyInfo.new(entry[0], entry[1], entry[3], entry[2], entry[4],
          pg_referential_action(entry[5]), pg_referential_action(entry[6]))
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

  # `pg_constraint` stores the action as one letter.
  private def pg_referential_action(code : String) : Grant::Schema::ReferentialAction
    case code
    when "c" then Grant::Schema::ReferentialAction::Cascade
    when "r" then Grant::Schema::ReferentialAction::Restrict
    when "n" then Grant::Schema::ReferentialAction::SetNull
    when "d" then Grant::Schema::ReferentialAction::SetDefault
    else          Grant::Schema::ReferentialAction::NoAction
    end
  end
end

require "./pg_test_helpers"

Grant::Adapter::Registry.register(Grant::Adapter::Pg, "postgres", "postgresql", "pg")
