# An app on the C SQLite library only (`grant/adapter/sqlite`, no engine
# require, no flags), run against a database file: it reads indexes through
# `Grant::Schema::Introspection`, removes and renames indexes and renames a
# table through the schema statements, dumps the schema, runs a seed, takes
# an advisory lock, and checks that
# `Grant.settings.sqlite_engine = :grant` is refused, naming the require.
# `scripts/check_sqlite3_linkage.rb` builds and runs it, so the C-only path
# is compiled in CI.
require "../../src/grant"
require "../../src/adapter/sqlite"

path = ARGV[0]? || File.tempname("grant_c_only_schema", ".sqlite3")
File.delete?(path)
adapter = Grant::Adapter::Sqlite.new(name: "primary", url: "sqlite3:#{path}")
Grant::Connections << adapter

statements = Grant::Schema::AdapterStatements.new(adapter)
statements.create_table(:c_only_pets, force: true) do |table|
  table.string :pet_name
  table.string :owner_email
  table.string :deleted_at
end
statements.add_index(:c_only_pets, :pet_name, name: "c_only_pets_by_name")
statements.add_index(:c_only_pets, :owner_email, unique: true, where: "deleted_at IS NULL")

list_of_indexes = Grant.schema(adapter).indexes(:c_only_pets)
partial = list_of_indexes.find! { |index| index.columns == ["owner_email"] }
puts "indexes: #{list_of_indexes.map(&.name).sort!.join(" ")}"
puts "partial where: #{partial.where}"

statements.rename_index(:c_only_pets, "c_only_pets_by_name", "c_only_pets_by_pet_name")
statements.remove_index(:c_only_pets, :owner_email)
statements.rename_table(:c_only_pets, :c_only_animals)
puts "after changes: #{Grant.schema(adapter).indexes(:c_only_animals).map(&.name).sort!.join(" ")}"

dump = Grant::Schema::Dumper.dump(adapter)
puts "dump names the table: #{dump.includes?("c_only_animals")}"
puts "dump names the index: #{dump.includes?("c_only_pets_by_pet_name")}"

ran = Grant::Seeds.load_once("c_only_probe", adapter) { }
puts "seed ran: #{ran}"
locked = adapter.open { |connection| adapter.try_advisory_lock(connection, "c_only_probe") }
puts "advisory lock taken: #{locked}"

puts "sqlite_engine: #{Grant.settings.sqlite_engine}"
begin
  Grant.settings.sqlite_engine = :grant
  puts "grant engine: accepted"
rescue error : ArgumentError
  puts "grant engine refused: #{error.message}"
end
File.delete?(path)
