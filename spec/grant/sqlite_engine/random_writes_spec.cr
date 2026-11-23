require "../../support/sqlite_engine/write_driver"

# Seeded random write sequences: schema changes, inserts, updates, deletes
# and transactions, applied through the engine's write API and, as SQL,
# through the sqlite3 tool. The regular run keeps one seed and a few dozen
# sequences so CI repeats; the nightly run sets
# SQLITE_ENGINE_WRITE_SEQUENCES=10000 with a fresh SQLITE_ENGINE_WRITE_SEED.
DEFAULT_WRITE_SEED = "20261123"

describe "Grant::SQLiteEngine random write sequences" do
  count = ENV.fetch("SQLITE_ENGINE_WRITE_SEQUENCES", "40").to_i
  seed = (ENV["SQLITE_ENGINE_WRITE_SEED"]? || DEFAULT_WRITE_SEED).to_i64

  it "writes files C SQLite accepts and reads as its own (#{count} sequences, seed #{seed})" do
    summary = SQLiteEngineWriteDriver.run(count, seed, keep: ENV["SQLITE_ENGINE_WRITE_FAILURES"]?)
    STDOUT.puts "\n  random writes: #{summary.sequences} sequences, seed #{seed}, #{summary.operations} operations, " \
                "#{summary.rows_compared} dump lines compared, #{summary.list_of_failures.size} failures"
    summary.list_of_failures.first(10).each { |failure| STDOUT.puts "  #{failure}" }
    summary.list_of_unexpected.first(10).each { |message| STDOUT.puts "  unexpected: #{message}" }
    summary.list_of_failures.should be_empty
    summary.list_of_unexpected.should be_empty
  end
end
