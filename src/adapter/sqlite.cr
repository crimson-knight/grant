require "./base"
require "sqlite3"
require "../grant/sqlite_version_check"

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
  
  def supports_lock_mode?(mode : Grant::Locking::LockMode) : Bool
    false
  end
  
  def supports_isolation_level?(level : Grant::Transaction::IsolationLevel) : Bool
    false
  end
  
  def supports_savepoints? : Bool
    true
  end
end
