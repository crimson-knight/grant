#!/usr/bin/ruby
# Writes the generated part of the migration corpus that
# scripts/sqlite_engine_migration_differential.cr replays:
#
#   spec/grant/sqlite_engine/migrations/amber_cli/  the migrations Amber V2's
#     generators write for a sqlite app (model, scaffold, migration, auth),
#     rendered the way amber_cli's `generate` command renders them
#   spec/grant/sqlite_engine/migrations/grant/spec_suite_migrations.sql
#     the migration statements Grant's own migrator, table rebuild, schema
#     tracking and internal metadata prepared in the committed SQL corpus
#
# The hand-written files under migrations/frameworks/ are not touched.
#
# Usage:
#   /usr/bin/ruby scripts/sqlite_engine_migration_corpus.rb AMBER_CLI_CHECKOUT
#
# AMBER_CLI_CHECKOUT is a clone of amberframework/amber_cli (branch main);
# the script checks that its generator still holds the SQL text it mirrors
# and stops when it does not, so a changed generator is noticed.
require "fileutils"

root = File.expand_path("..", __dir__)
corpus_directory = File.join(root, "spec/grant/sqlite_engine/migrations")
amber_cli = ARGV[0] or abort("usage: #{$0} AMBER_CLI_CHECKOUT")
generator_path = File.join(amber_cli, "src/amber_cli/commands/generate.cr")
generator = File.read(generator_path)

# The generator text this script mirrors; each must still be present.
MIRRORED = [
  %q(when "string", "email"         then "VARCHAR(255)"),
  %q(when "uuid"                    then database_type == "pg" ? "UUID" : "VARCHAR(36)"),
  %q(when "int64", "reference"      then "BIGINT"),
  %q(when "float", "float64"        then "DOUBLE PRECISION"),
  %q(when "decimal"                 then "DECIMAL(10,2)"),
  %q(when "bool", "boolean"         then "BOOLEAN DEFAULT FALSE"),
  %q(when "time", "timestamp"       then "TIMESTAMP"),
  %q("CREATE INDEX IF NOT EXISTS index_#{table_name}_on_#{field_name} ON #{table_name} (#{field_name});\n"),
  'CREATE TABLE IF NOT EXISTS #{table_name} (',
  %q("id INTEGER PRIMARY KEY AUTOINCREMENT"),
  %q(DROP TABLE IF EXISTS #{table_name};),
]
MIRRORED.each do |text|
  abort "amber_cli's generator no longer contains #{text.inspect}; update this script" unless generator.include?(text)
end
commit = Dir.chdir(amber_cli) { `git rev-parse HEAD`.strip }

SQL_TYPES = {
  "string" => "VARCHAR(255)", "email" => "VARCHAR(255)", "uuid" => "VARCHAR(36)", "text" => "TEXT",
  "integer" => "INTEGER", "int" => "INTEGER", "int32" => "INTEGER", "int64" => "BIGINT",
  "reference" => "BIGINT", "float" => "DOUBLE PRECISION", "float64" => "DOUBLE PRECISION",
  "decimal" => "DECIMAL(10,2)", "bool" => "BOOLEAN DEFAULT FALSE", "boolean" => "BOOLEAN DEFAULT FALSE",
  "time" => "TIMESTAMP", "timestamp" => "TIMESTAMP",
}

# `amber generate model|scaffold NAME field:type[:required] ...` for sqlite.
def create_table_migration(table_name, arguments)
  fields = arguments.map do |argument|
    name, type, flag = argument.split(":")
    required = flag == "required"
    if type == "reference"
      name = "#{name.chomp("_id")}_id"
      required = true
    end
    [name, type, required]
  end
  columns = fields.map do |name, type, required|
    "  #{name} #{SQL_TYPES.fetch(type, "VARCHAR(255)")}#{required ? " NOT NULL" : ""}"
  end.join(",\n")
  field_sql = columns.empty? ? "" : "#{columns},\n"
  indexes = fields.select { |_, type, _| type == "reference" }.map do |name, _, _|
    "CREATE INDEX IF NOT EXISTS index_#{table_name}_on_#{name} ON #{table_name} (#{name});\n"
  end.join
  <<~SQL
    -- +micrate Up
    -- Create #{table_name} table
    CREATE TABLE IF NOT EXISTS #{table_name} (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
    #{field_sql}  created_at TIMESTAMP,
      updated_at TIMESTAMP
    );
    #{indexes}
    -- +micrate Down
    DROP TABLE IF EXISTS #{table_name};
  SQL
end

# Rows the app writes between the Up and the Down, so the comparison covers
# defaults and affinities as well as the schema.
def sample_rows(table_name, arguments)
  values = arguments.map do |argument|
    name, type = argument.split(":")
    name = "#{name.chomp("_id")}_id" if type == "reference"
    literal = case type
              when "integer", "int", "int32", "int64", "reference" then "'42'"
              when "float", "float64", "decimal"                     then "'12.50'"
              when "bool", "boolean"                                 then "1"
              when "time", "timestamp"                               then "'2026-11-25 10:00:00.000'"
              else                                                        "'Text value'"
              end
    [name, literal]
  end
  names = (values.map(&:first) + %w[created_at updated_at]).join(", ")
  literals = (values.map(&:last) + ["CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP"]).join(", ")
  "INSERT INTO #{table_name} (#{names}) VALUES (#{literals});\nINSERT INTO #{table_name} DEFAULT VALUES;\n"
end

amber_directory = File.join(corpus_directory, "amber_cli")
FileUtils.rm_rf(amber_directory)
FileUtils.mkdir_p(amber_directory)
header = "-- Generated by scripts/sqlite_engine_migration_corpus.rb from amber_cli #{commit}.\n"
{
  "model_post" => ["posts", %w[title:string body:text published:bool views:integer user:reference]],
  "scaffold_product" => ["products", %w[name:string:required sku:uuid price:decimal weight:float stock:int64 released_at:time]],
  "model_comment" => ["comments", %w[body:text post:reference author_id:reference rating:int32]],
  "migration_create_events" => ["events", %w[title:string starts_at:timestamp all_day:boolean contact:email]],
  "auth_user" => ["users", %w[email:string:required password_digest:string:required]],
}.each do |name, (table, arguments)|
  migration = create_table_migration(table, arguments)
  up, down = migration.split("-- +micrate Down")
  body = up + sample_rows(table, arguments) + "-- +micrate Down" + down
  File.write(File.join(amber_directory, "#{name}.sql"), header + body)
end
# `amber generate migration AddStatusToUsers` with no fields: an empty
# Up and Down, which the app's author fills in by hand.
File.write(File.join(amber_directory, "migration_empty.sql"), header + <<~SQL)
  -- Migration: add_status_to_users
  -- Created: 2026-11-25 00:00:00 UTC

  -- +micrate Up
  -- Add SQL to apply the migration here.

  -- +micrate Down
  -- Add SQL to roll the migration back here.
SQL
# The migration/full template (Helpers::Migration), kept in amber_cli's
# template tree, renders a sqlite key as "id INTEGER NOT NULL PRIMARY KEY".
File.write(File.join(amber_directory, "template_full_create_article.sql"), header + <<~SQL)
  -- +micrate Up
  CREATE TABLE articles (
    id INTEGER NOT NULL PRIMARY KEY,
    title VARCHAR,
    body TEXT,
    author_id INTEGER
  );
  CREATE INDEX article_author_id_idx ON articles (author_id);
  INSERT INTO articles (title, body, author_id) VALUES ('First', 'Body', 7);

  -- +micrate Down
  DROP TABLE IF EXISTS articles;
SQL

# Grant's migrator, schema tracking and table rebuild statements: the
# migration specs' part of the committed corpus (from the first migrator
# statement on), without statements that take bound parameters.
grant_corpus = File.join(root, "spec/grant/sqlite_engine/corpus/grant_sql_corpus.txt")
lines = File.readlines(grant_corpus, chomp: true)
first = lines.index { |line| line.include?("migrator_default_literal_rows") } or abort "the migrator statements moved in #{grant_corpus}"
statements = lines[first..].reject { |line| line.include?("?") || line.strip.empty? }
File.write(File.join(corpus_directory, "grant", "spec_suite_migrations.sql"),
  "-- Generated by scripts/sqlite_engine_migration_corpus.rb from spec/grant/sqlite_engine/corpus/grant_sql_corpus.txt\n" \
  "-- (lines #{first + 1}..#{lines.size}, statements without bound parameters).\n" +
  statements.map { |line| line.rstrip.sub(/;\s*\z/, "") + ";\n" }.join)
puts "amber_cli #{commit}: #{Dir[File.join(amber_directory, "*.sql")].size} files; grant: #{statements.size} statements"
