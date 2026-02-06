require "../grant"
require "db"
require "colorize"

# The Base Adapter specifies the interface that will be used by the model
# objects to perform actions against a specific database.  Each adapter needs
# to implement these methods.
abstract class Grant::Adapter::Base
  getter name : String
  getter url : String
  private property _database : DB::Database?

  private SQL_KEYWORDS = Set(String).new(%w(
    ALTER AND ANY AS ASC COLUMN CONSTRAINT COUNT CREATE DEFAULT DELETE DESC
    DISTINCT DROP ELSE EXISTS FALSE FOREIGN FROM GROUP HAVING IF IN INDEX INNER
    INSERT INTO JOIN LIMIT NOT NULL ON OR ORDER PRIMARY REFERENCES RELEASE RETURNING
    SELECT SET TABLE THEN TRUE UNION UNIQUE UPDATE USING VALUES WHEN WHERE
  ))

  def initialize(@name : String, @url : String)
  end

  def database : DB::Database
    @_database ||= DB.open(@url)
  end

  def open(&)
    database.retry do
      database.using_connection do |conn|
        yield conn
      rescue ex : IO::Error
        raise ::DB::ConnectionLost.new(conn)
      rescue ex : Exception
        if ex.message =~ /client was disconnected/
          raise ::DB::ConnectionLost.new(conn)
        else
          raise ex
        end
      end
    end
  end

  def log(query : String, elapsed_time : Time::Span, params = [] of String) : Nil
    Log.debug { colorize query, params, elapsed_time.total_seconds }
  end

  # remove all rows from a table and reset the counter on the id.
  abstract def clear(table_name : String)

  # select performs a query against a table.  The query object contains table_name,
  # fields (configured using the sql_mapping directive in your model), and an optional
  # raw query string.  The clause and params is the query and params that is passed
  # in via .all() method
  def select(query : Grant::Select::Container, clause = "", params = [] of DB::Any, &)
    clause = ensure_clause_template(clause)
    statement = query.custom ? "#{query.custom} #{clause}" : String.build do |stmt|
      stmt << "SELECT "
      stmt << query.fields.map { |name| "#{quote(query.table_name)}.#{quote(name)}" }.join(", ")
      stmt << " FROM #{quote(query.table_name)} #{clause}"
    end

    elapsed_time = Time.measure do
      open do |db|
        db.query statement, args: params do |rs|
          yield rs
        end
      end
    end

    log statement, elapsed_time, params
  end

  # Returns `true` if a record exists that matches *criteria*, otherwise `false`.
  def exists?(table_name : String, criteria : String, params = [] of Grant::Columns::Type) : Bool
    statement = "SELECT EXISTS(SELECT 1 FROM #{table_name} WHERE #{ensure_clause_template(criteria)})"

    exists = false
    elapsed_time = Time.measure do
      open do |db|
        exists = db.query_one?(statement, args: params, as: Bool) || exists
      end
    end

    log statement, elapsed_time, params

    exists
  end

  # Converts placeholder characters in a SQL clause to the adapter's
  # native parameter syntax. The base implementation is a no-op since
  # SQLite and MySQL use `?` natively. The PG adapter overrides this
  # to convert `?` to `$1`, `$2`, etc.
  def ensure_clause_template(clause : String) : String
    clause
  end

  # This will insert a row in the database and return the id generated.
  abstract def insert(table_name : String, fields, params, lastval) : Int64

  # This will insert an array of models as one insert statement
  abstract def import(table_name : String, primary_name : String, auto : Bool, fields, model_array, **options)

  # This will update a row in the database.
  abstract def update(table_name : String, primary_name : String, fields, params)
  
  # Update with custom WHERE clause for composite keys
  def update_with_where(table_name : String, fields : Array(String), params : Array(DB::Any), where_clause : String)
    statement = String.build do |stmt|
      stmt << "UPDATE #{quote(table_name)} SET "
      stmt << fields.map { |field| "#{quote(field)} = ?" }.join(", ")
      stmt << " WHERE #{where_clause}"
    end
    statement = ensure_clause_template(statement)

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, args: params
      end
    end

    log statement, elapsed_time, params
  end

  # This will delete a row from the database.
  abstract def delete(table_name : String, primary_name : String, value)
  
  # Delete with custom WHERE clause for composite keys
  def delete_with_where(table_name : String, where_clause : String, params : Array(DB::Any))
    statement = "DELETE FROM #{quote(table_name)} WHERE #{ensure_clause_template(where_clause)}"

    elapsed_time = Time.measure do
      open do |db|
        db.exec statement, args: params
      end
    end

    log statement, elapsed_time, params
  end

  module Schema
    TYPES = {
      "Bool"    => "BOOL",
      "Float32" => "FLOAT",
      "Float64" => "REAL",
      "Int32"   => "INT",
      "Int64"   => "BIGINT",
      "String"  => "VARCHAR(255)",
      "Time"    => "TIMESTAMP",
    }
  end

  # Use macro in order to read a constant defined in each subclasses.
  macro inherited
    # quotes table and column names
    def quote(name : String) : String
      String.build do |str|
        str << QUOTING_CHAR
        str << name
        str << QUOTING_CHAR
      end
    end

    # converts the crystal class to database type of this adapter
    def self.schema_type?(key : String) : String?
      Schema::TYPES[key]? || Grant::Adapter::Base::Schema::TYPES[key]?
    end
  end

  private def colorize(query : String, params, elapsed_time : Float64) : String
    q = query.to_s.split(/([a-zA-Z0-9_$']+)/).map do |word|
      if SQL_KEYWORDS.includes?(word.upcase)
        word.colorize.bold.blue.to_s
      elsif !word.starts_with?('$') && word =~ /\d+/
        word.colorize.light_red
      elsif word.starts_with?('\'') && word.ends_with?('\'')
        word.colorize(Colorize::Color256.new(193))
      else
        word.colorize.white
      end
    end.join

    "[#{humanize_duration(elapsed_time)}] #{q}: #{params.colorize.light_magenta}"
  end

  private def humanize_duration(elapsed_time : Float64)
    if elapsed_time > 0.1
      "#{(elapsed_time).*(100).trunc./(100)}s".colorize.red
    elsif elapsed_time > 0.001
      "#{(elapsed_time * 1_000).trunc}ms".colorize.yellow
    elsif elapsed_time > 0.000_001
      "#{(elapsed_time * 1_000_000).trunc}µs".colorize.green
    elsif elapsed_time > 0.000_000_001
      "#{(elapsed_time * 1_000_000_000).trunc}ns".colorize.green
    else
      "<1ns".colorize.green
    end
  end
  
  # Methods for checking database capabilities
  abstract def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
  abstract def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
  abstract def supports_savepoints? : Bool
end
