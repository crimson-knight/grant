require "../../support/sqlite_engine/crash_driver"

# Crash simulation over small random write sequences in
# journal_mode=DELETE: every write, sync, truncate and delete of every unit
# is a crash point. The regular run keeps one seed and a few sequences; the
# nightly run sets SQLITE_ENGINE_CRASH_SEQUENCES=1000 with a fresh
# SQLITE_ENGINE_CRASH_SEED.
DEFAULT_CRASH_SEED = "20261123"

describe "Grant::SQLiteEngine crash recovery" do
  count = ENV.fetch("SQLITE_ENGINE_CRASH_SEQUENCES", "6").to_i
  seed = (ENV["SQLITE_ENGINE_CRASH_SEED"]? || DEFAULT_CRASH_SEED).to_i64

  it "recovers every crash point to the state before or after the write (#{count} sequences, seed #{seed})" do
    summary = SQLiteEngineCrashDriver.run(count, seed)
    STDOUT.puts "\n  crash simulation: #{summary.sequences} sequences, seed #{seed}, #{summary.units} write units, " \
                "#{summary.crash_points} crash points, #{summary.states_checked} distinct crash states opened by the engine, " \
                "#{summary.sqlite3_states_checked} by sqlite3, #{summary.list_of_failures.size} neither old nor new"
    summary.list_of_failures.first(10).each { |failure| STDOUT.puts "  #{failure}" }
    summary.list_of_failures.should be_empty
  end
end

# The same in journal_mode=WAL, with checkpoints as steps, wal-index writes
# as crash points, and process crashes that leave the wal-index to a
# surviving process. Half the sequences commit with synchronous=FULL, half
# with NORMAL. The nightly run sets SQLITE_ENGINE_WAL_CRASH_SEQUENCES=1000.
describe "Grant::SQLiteEngine crash recovery in WAL mode" do
  count = ENV.fetch("SQLITE_ENGINE_WAL_CRASH_SEQUENCES", "6").to_i
  seed = (ENV["SQLITE_ENGINE_CRASH_SEED"]? || DEFAULT_CRASH_SEED).to_i64

  it "recovers every crash point to the state before or after the step (#{count} sequences, seed #{seed})" do
    full = SQLiteEngineCrashDriver.run((count + 1) // 2, seed, wal: true, synchronous: Grant::SQLiteEngine::Synchronous::Full)
    normal = SQLiteEngineCrashDriver.run(count // 2, seed + 500_000, wal: true, synchronous: Grant::SQLiteEngine::Synchronous::Normal)
    list_of_failures = full.list_of_failures + normal.list_of_failures
    STDOUT.puts "\n  WAL crash simulation: #{full.sequences + normal.sequences} sequences (#{full.sequences} synchronous=FULL, seed #{seed}; " \
                "#{normal.sequences} NORMAL, seed #{seed + 500_000}), #{full.units + normal.units} steps, " \
                "#{full.crash_points + normal.crash_points} crash points, #{full.states_checked + normal.states_checked} distinct crash states " \
                "opened by the engine, #{full.sqlite3_states_checked + normal.sqlite3_states_checked} by sqlite3, " \
                "#{list_of_failures.size} neither old nor new"
    list_of_failures.first(10).each { |failure| STDOUT.puts "  #{failure}" }
    list_of_failures.should be_empty
  end
end
