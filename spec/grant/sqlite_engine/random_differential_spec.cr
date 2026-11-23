require "./support/differential"

# A seeded sweep over random schemas and contents (page sizes, encodings,
# auto-vacuum modes, WAL, WITHOUT ROWID, ALTER TABLE ADD COLUMN, overflow,
# deletes). The regular run builds a few dozen databases; the nightly run sets
# SQLITE_ENGINE_RANDOM_DATABASES=1000 (and SQLITE_ENGINE_RANDOM_SEED to replay).
describe "Grant::SQLiteEngine random differential" do
  count = ENV.fetch("SQLITE_ENGINE_RANDOM_DATABASES", "40")
  seed = ENV["SQLITE_ENGINE_RANDOM_SEED"]? || Random.rand(1_000_000).to_s
  directory, manifest = SQLiteEngineDifferential.generate("random", ["--count", count, "--seed", seed])

  it "reads #{count} random databases as C SQLite does (seed #{seed})" do
    comparisons = manifest.fixtures.map { |fixture| SQLiteEngineDifferential.compare(directory, fixture.name) }
    mismatched = comparisons.select(&.first_difference)
    STDOUT.puts "\n  random differential: #{comparisons.size} databases, seed #{manifest.seed}, " \
                "#{comparisons.sum(&.objects)} tables and indexes, #{comparisons.sum(&.lines)} lines, #{mismatched.size} mismatched"
    mismatched.first(5).each { |comparison| STDOUT.puts "  #{comparison.fixture}: #{comparison.first_difference}" }
    mismatched.should be_empty
  end
end
