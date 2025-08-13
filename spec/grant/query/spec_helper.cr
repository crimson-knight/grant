require "spec"
require "db"
require "../../../src/grant/query/builder"

class Model
  def self.table_name
    "table"
  end

  def self.fields
    ["name", "age"]
  end

  def self.primary_name
    "id"
  end
end

def query_fields
  Model.fields.join ", "
end

def builder
  {% if env("CURRENT_ADAPTER").id == "pg" %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Pg
  {% elsif env("CURRENT_ADAPTER").id == "mysql" %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Mysql
  {% else %}
    Grant::Query::Builder(Model).new Grant::Query::Builder::DbType::Sqlite
  {% end %}
end

def ignore_whitespace(expected : String)
  whitespace = "\\s+?"
  compiled = expected.split(/\s/).map { |s| Regex.escape s }.join(whitespace)
  Regex.new "^\\s*#{compiled}\\s*$", Regex::Options::IGNORE_CASE ^ Regex::Options::MULTILINE
end
