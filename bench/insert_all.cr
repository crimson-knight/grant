# bench/insert_all.cr
#
# Compares `insert_all` (multi-row VALUES, chunked under the bind cap) with a
# per-row `save` loop at 10,000 rows, and exits non-zero unless the bulk path is
# at least 10x faster.
#
#   CURRENT_ADAPTER=sqlite crystal-alpha run --release bench/insert_all.cr
#   CURRENT_ADAPTER=pg PG_DATABASE_URL=postgres://localhost/grant_bench crystal-alpha run --release bench/insert_all.cr

require "pg"
require "sqlite3"
require "../src/grant"
require "../src/adapter/pg"
require "../src/adapter/sqlite"

Log.setup(:warn)

ROWS         = 10_000
REQUIRED_MIN =   10.0

adapter_name = ENV["CURRENT_ADAPTER"]? || "sqlite"
if adapter_name == "pg"
  Grant::Connections << Grant::Adapter::Pg.new(name: "bench_insert", url: ENV["PG_DATABASE_URL"])
else
  path = File.join(Dir.tempdir, "grant_bench_insert_all_#{Process.pid}.db")
  at_exit { File.delete?(path) }
  Grant::Connections << Grant::Adapter::Sqlite.new(name: "bench_insert", url: "sqlite3:#{path}")
end

class BenchInsertRow < Grant::Base
  connection bench_insert
  table bench_insert_rows

  column id : Int64, primary: true
  column label : String
  column amount : Int32
  column created_at : Time?
  column updated_at : Time?
end

BenchInsertRow.migrator.drop_and_create

attributes = Array.new(ROWS) { |index| {"label" => "row #{index}", "amount" => index} }

per_row = Time.measure do
  attributes.each do |row|
    BenchInsertRow.new(label: row["label"].as(String), amount: row["amount"].as(Int32)).save!
  end
end
raise "per-row save wrote #{BenchInsertRow.count} rows" unless BenchInsertRow.count == ROWS
BenchInsertRow.clear

bulk = Time.measure { BenchInsertRow.insert_all(attributes, returning: [] of Symbol) }
raise "insert_all wrote #{BenchInsertRow.count} rows" unless BenchInsertRow.count == ROWS
BenchInsertRow.clear

with_keys = Time.measure { BenchInsertRow.insert_all(attributes) }
raise "insert_all wrote #{BenchInsertRow.count} rows" unless BenchInsertRow.count == ROWS

speedup = per_row.total_seconds / bulk.total_seconds
puts "adapter=#{adapter_name} rows=#{ROWS}"
puts "per-row save: #{(per_row.total_milliseconds).round(1)} ms"
puts "insert_all:   #{(bulk.total_milliseconds).round(1)} ms (returning: [])"
puts "insert_all:   #{(with_keys.total_milliseconds).round(1)} ms (default, returns primary keys)"
puts "speedup:      #{speedup.round(1)}x (required >= #{REQUIRED_MIN}x)"
exit(speedup >= REQUIRED_MIN ? 0 : 1)
