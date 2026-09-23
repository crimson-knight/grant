require "spec"
require "db"
require "pg"
require "sqlite3"
require "../../../src/grant"
require "../../../src/adapter/**"
require "../../../src/grant/locking"
require "../../../src/adapter/base"
require "../../../src/grant/query/builder"
require "../../../src/grant/query/executors/**"
require "../../../src/grant/query/assemblers/base"
require "../../../src/grant/query/assemblers/sqlite"
require "../../../src/grant/query/assemblers/pg"
require "../../../src/grant/query/assemblers/mysql"
require "../../../src/grant/scale/index_hints"

class Model
  def self.table_name
    "table"
  end

  def self.fields
    ["id", "name", "age", "date_completed", "status", "published"]
  end

  def self.primary_name
    "id"
  end

  # Stub for assembler compile compatibility (lock mode needs adapter type)
  def self.adapter : Grant::Adapter::Base
    raise NotImplementedError.new("Model.adapter not available in query builder specs")
  end

  def self.quote(name : String) : String
    %("#{name}")
  end

  def self.custom_select_statement : String?
    nil
  end
end

def query_fields
  Model.fields.join ", "
end

def builder
{% if (env("CURRENT_ADAPTER") || "sqlite").id == "pg" %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Pg
  {% elsif (env("CURRENT_ADAPTER") || "sqlite").id == "mysql" %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Mysql
  {% else %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Sqlite
  {% end %}
end

def pg_builder
  Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Pg
end

def sqlite_builder
  Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Sqlite
end

def ignore_whitespace(expected : String)
  whitespace = "\\s+?"
  compiled = expected.split(/\s/).map { |s| Regex.escape s }.join(whitespace)
  Regex.new "^\\s*#{compiled}\\s*$", Regex::Options::IGNORE_CASE ^ Regex::Options::MULTILINE
end
