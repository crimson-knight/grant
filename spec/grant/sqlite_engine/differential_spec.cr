require "./support/differential"

describe "Grant::SQLiteEngine differential against the sqlite3 tool" do
  directory, manifest = SQLiteEngineDifferential.generate("standard")

  it "builds the standard fixtures with the sqlite3 tool" do
    manifest.fixtures.size.should be >= 26
    manifest.sqlite3_version.should_not be_empty
    manifest.fixtures.each do |fixture|
      SQLiteEngineDifferential.sha256(directory / "#{fixture.name}.db").should eq(fixture.sha256)
    end
  end

  manifest.fixtures.each do |fixture|
    it "reads every row and index entry of #{fixture.name} as C SQLite does" do
      comparison = SQLiteEngineDifferential.compare(directory, fixture.name)
      comparison.first_difference.should be_nil
      comparison.objects.should be > 0
    end
  end

  it "reports the fixtures, objects and lines compared" do
    comparisons = manifest.fixtures.map { |fixture| SQLiteEngineDifferential.compare(directory, fixture.name) }
    failed = comparisons.count(&.first_difference)
    STDOUT.puts "\n  differential: #{comparisons.size} fixtures, #{comparisons.sum(&.objects)} tables and indexes, " \
                "#{comparisons.sum(&.lines)} lines compared, #{failed} mismatched (sqlite3 #{manifest.sqlite3_version.split(' ').first})"
    failed.should eq(0)
  end

  it "reads rows that exist only in the -wal file" do
    database = Grant::SQLiteEngine::Database.open(directory / "wal_committed.db")
    labels = database.rows("events").map(&.values[1])
    database.close
    labels.count { |label| label.as?(String).try(&.starts_with?("only in the wal")) }.should eq(30)
    labels.should contain("updated in the wal")
    labels.size.should eq(79)
  end

  it "leaves the database, its -wal and its -shm untouched" do
    path = directory / "wal_committed.db"
    shm = Path["#{path}-shm"]
    File.delete?(shm)
    before = {SQLiteEngineDifferential.sha256(path), SQLiteEngineDifferential.sha256(Path["#{path}-wal"])}
    database = Grant::SQLiteEngine::Database.open(path)
    Grant::SQLiteEngine::Dump.new(database).write(IO::Memory.new)
    database.close
    {SQLiteEngineDifferential.sha256(path), SQLiteEngineDifferential.sha256(Path["#{path}-wal"])}.should eq(before)
    File.exists?(shm).should be_false
  end
end

describe "Grant::SQLiteEngine on Grant's own schema" do
  directory, manifest = SQLiteEngineDifferential.generate("corpus", ["--corpus", SQLiteEngineDifferential::CORPUS.to_s, "--seed", "20261122"])

  it "reads a database holding every table and index Grant's spec suite created" do
    fixture = manifest.fixtures.first
    (fixture.tables || 0).should be > 100
    comparison = SQLiteEngineDifferential.compare(directory, fixture.name)
    STDOUT.puts "\n  corpus schema: #{fixture.create_statements} CREATE statements (#{fixture.create_statements_accepted} accepted by sqlite3), " \
                "#{fixture.tables} tables, #{fixture.rows} rows, #{comparison.objects} tables and indexes, #{comparison.lines} lines compared"
    comparison.first_difference.should be_nil
  end
end
