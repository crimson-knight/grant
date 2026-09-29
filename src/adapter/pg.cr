require "pg"
require "./base"

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
      stmt << position_str(fields.size)
      stmt << ")"

      stmt << " RETURNING #{quote(lastval)}" if lastval
    end

    last_id = -1_i64
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
end
