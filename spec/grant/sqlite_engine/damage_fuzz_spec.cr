require "../../support/sqlite_engine/differential"
require "../../support/sqlite_engine/damage_fuzzer"

# Seeded damage fuzzing over the smaller standard fixtures. The regular run
# mutates a few thousand copies; the nightly run sets
# SQLITE_ENGINE_FUZZ_CASES=100000 (and SQLITE_ENGINE_FUZZ_SEED to replay).
describe "Grant::SQLiteEngine damaged files" do
  directory, manifest = SQLiteEngineDifferential.generate("standard")
  case_count = ENV.fetch("SQLITE_ENGINE_FUZZ_CASES", "3000").to_i
  seed = (ENV["SQLITE_ENGINE_FUZZ_SEED"]? || Random.rand(1_000_000).to_s).to_i64

  it "opens every mutated file cleanly or raises a named error (#{case_count} cases, seed #{seed})" do
    seeds = manifest.fixtures.compact_map do |fixture|
      path = directory / "#{fixture.name}.db"
      next if File.size(path) > 200_000
      wal_path = Path["#{path}-wal"]
      wal = File.exists?(wal_path) ? File.read(wal_path).to_slice : nil
      SQLiteEngineDamageFuzzer::Seed.new(fixture.name, File.read(path).to_slice, wal)
    end
    seeds.size.should be >= 8
    fuzzer = SQLiteEngineDamageFuzzer.new(seeds, seed)
    fuzzer.run(case_count)
    STDOUT.puts "\n  damage fuzz: #{fuzzer.cases_run} cases over #{seeds.size} fixtures, seed #{seed}: " \
                "#{fuzzer.clean_reads} read cleanly, #{fuzzer.corrupt_database_raised} raised CorruptDatabase, " \
                "other named errors #{fuzzer.other_named_errors}, #{fuzzer.list_of_failures.size} failures; " \
                "slowest #{(fuzzer.slowest_case_seconds * 1000).round(2)} ms (#{fuzzer.slowest_case}), " \
                "largest heap growth #{fuzzer.largest_heap_growth // 1024} KiB"
    regression_directory = ENV["SQLITE_ENGINE_FUZZ_FAILURES"]?
    fuzzer.list_of_failures.first(10).each do |failure|
      STDOUT.puts "  case #{failure.case_number} #{failure.fixture} #{failure.mutation}: #{failure.detail}"
      if regression_directory
        Dir.mkdir_p(regression_directory)
        File.write(Path[regression_directory] / "case_#{failure.case_number}.db", failure.database)
        if wal = failure.wal
          File.write(Path[regression_directory] / "case_#{failure.case_number}.db-wal", wal)
        end
      end
    end
    fuzzer.list_of_failures.should be_empty
  end
end
