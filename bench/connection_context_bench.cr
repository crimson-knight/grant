# Queries per second through the connection-context lookup path with many
# fibers: every query resolves current_role / current_shard / connection_context
# before it reaches the adapter.
#
#   CURRENT_ADAPTER=sqlite crystal-alpha run --release bench/connection_context_bench.cr
#
# Optional: FIBERS (default 100), QUERIES_PER_FIBER (default 200).
require "../src/grant"
require "../src/adapter/sqlite"

path = File.join(Dir.tempdir, "grant_context_bench_#{Process.pid}.sqlite3")
DB.open("sqlite3:#{path}") do |db|
  db.exec "CREATE TABLE bench_rows (id INTEGER PRIMARY KEY, label TEXT)"
  db.exec "INSERT INTO bench_rows (label) VALUES ('a')"
end
Grant::ConnectionRegistry.establish_connection(
  database: "bench", adapter: Grant::Adapter::Sqlite, url: "sqlite3:#{path}", pool_size: 25)

class BenchRow < Grant::Base
  connection bench
  table bench_rows
  column id : Int64, primary: true
  column label : String?
end

fibers = (ENV["FIBERS"]? || "100").to_i
per_fiber = (ENV["QUERIES_PER_FIBER"]? || "200").to_i

# Warm up the pool and code paths.
BenchRow.find(1)

def run(fibers : Int32, per_fiber : Int32, &block : -> Nil) : Float64
  done = Channel(Nil).new
  started = Time.instant
  fibers.times do
    spawn do
      per_fiber.times { block.call }
      done.send(nil)
    end
  end
  fibers.times { done.receive }
  (fibers * per_fiber) / (Time.instant - started).total_seconds
end

plain = run(fibers, per_fiber) { BenchRow.find(1); nil }
inside = run(fibers, per_fiber) do
  BenchRow.connected_to(role: :writing) { BenchRow.find(1) }
  nil
end
lookups = run(fibers, per_fiber * 50) { BenchRow.current_role; BenchRow.current_shard; BenchRow.connection_context; nil }

puts "fibers=#{fibers} queries/fiber=#{per_fiber}"
puts "queries/sec plain:        #{plain.round(0)}"
puts "queries/sec connected_to: #{inside.round(0)}"
puts "context lookups/sec:      #{lookups.round(0)}"
File.delete?(path)
