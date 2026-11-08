{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "spec"
require "../../../../../src/grant/drivers/pg/pg"

PG_DRIVER_DB_URL = ENV["PG_DATABASE_URL"]? || "postgres:///"
PG_DRIVER_DB     = DB.open(PG_DRIVER_DB_URL)

def with_pg_driver_db(&)
  DB.open(PG_DRIVER_DB_URL) do |db|
    yield db
  end
end

def with_pg_driver_connection(&)
  DB.connect(PG_DRIVER_DB_URL) do |conn|
    yield conn
  end
end

def escape_pg_driver_literal(string)
  with_pg_driver_connection &.escape_literal(string)
end

def escape_pg_driver_identifier(string)
  with_pg_driver_connection &.escape_identifier(string)
end

module PgDriverSpecHelper
  def self.db_version_gte(major, minor = 0, patch = 0)
    ver = with_pg_driver_connection &.version
    ver[:major] >= major && ver[:minor] >= minor && ver[:patch] >= patch
  end
end

def test_pg_driver_decode(name, query, expected, file = __FILE__, line = __LINE__, *, time_zone : Time::Location? = nil)
  it name, file, line do
    PG_DRIVER_DB.using_connection do |c|
      old_time_zone = c.time_zone
      c = c.as Grant::PG::Connection
      begin
        if time_zone
          old_time_zone = c.time_zone
          c.exec "SET TIME ZONE '#{time_zone.name}'"
        end
        value = c.query_one "select #{query}", &.read
        value.should eq(expected), file: file, line: line
      ensure
        if old_time_zone
          c.exec "SET TIME ZONE '#{old_time_zone.name}'"
        end
      end
    end
  end
end

def test_pg_driver_decode(name, query, expected : JSON::PullParser, file = __FILE__, line = __LINE__)
  it name, file, line do
    value = PG_DRIVER_DB.query_one "select #{query}", &.read
    json_value = value.is_a?(JSON::PullParser) ? JSON::Any.new(value) : value
    json_value.should eq(JSON::Any.new(expected)), file: file, line: line
  end
end

def pg_driver_env_var_bubble(&)
  orig_vals = Hash(String, String).new
  vars = ["PGDATABASE", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGPASSFILE"]
  begin
    vars.each do |var|
      if ENV.has_key?(var)
        orig_vals[var] = ENV[var]
        ENV.delete(var)
      end
    end
    yield
  ensure
    vars.each do |var|
      ENV.delete(var)
      ENV[var] = orig_vals[var] if orig_vals.has_key?(var)
    end
  end
end
