require "../../support/sqlite_engine/write_driver"

# Every CREATE TABLE and CREATE INDEX Grant's spec suite issued, created
# through the engine's write API in corpus order, with the rows sqlite3 kept
# when it built the same schema (5 per table) inserted through the API too.
module SQLiteEngineCorpusWrites
  struct CorpusRow
    include JSON::Serializable

    getter table : String
    getter rowid : String?
    @[JSON::Field(key: "values")]
    getter list_of_values : Array(SQLiteEngineWriteDriver::TypedValue?)
  end

  struct Corpus
    include JSON::Serializable

    @[JSON::Field(key: "statements")]
    getter list_of_statements : Array(String)
    @[JSON::Field(key: "accepted")]
    getter list_of_accepted : Array(Bool)
    @[JSON::Field(key: "rows")]
    getter list_of_rows : Array(CorpusRow)
    getter manifest : SQLiteEngineDifferential::ManifestEntry
  end

  # Dump sections ("# table x" or "# index y" and their lines) of objects
  # not in *skipped*.
  def self.without(dump : String, skipped : Set(String)) : String
    keep = true
    String.build do |io|
      dump.each_line(chomp: false) do |line|
        if line.starts_with?("# ")
          keep = !skipped.includes?(line.split(' ', 3)[2].strip)
        end
        io << line if keep
      end
    end
  end
end

describe "Grant::SQLiteEngine writes Grant's own schema" do
  it "creates every corpus table and index and inserts their rows as sqlite3 does" do
    directory = Path[Dir.tempdir] / "grant-sqlite-engine-corpus-writes-#{Process.pid}"
    FileUtils.rm_rf(directory)
    Dir.mkdir_p(directory)
    SQLiteEngineWriteDriver.ruby(["corpus", directory.to_s, "--corpus", SQLiteEngineDifferential::CORPUS.to_s, "--seed", "20261122"])
    corpus = SQLiteEngineCorpusWrites::Corpus.from_json(File.read(directory / "corpus.json"))
    path = (directory / "grant_corpus_schema.e.db").to_s
    database = Grant::SQLiteEngine::Database.open(path, read_write: true)
    created = 0
    list_of_rejections = [] of String
    list_of_disagreements = [] of String
    corpus.list_of_statements.each_with_index do |sql, position|
      statement = sql.sub(/;?\s*\z/, "")
      begin
        statement.matches?(/\A\s*CREATE\s+TABLE/i) ? database.create_table(statement) : database.create_index(statement)
        created += 1
        list_of_disagreements << "engine accepted, sqlite3 rejected: #{statement[0, 200]}" unless corpus.list_of_accepted[position]
      rescue error : Grant::SQLiteEngine::Error
        list_of_disagreements << "sqlite3 accepted, engine rejected (#{error.message}): #{statement[0, 200]}" if corpus.list_of_accepted[position]
        list_of_rejections << "#{error.class.name.split("::").last}: #{error.message.to_s[0, 160]}"
      end
    end
    skipped = Set(String).new
    inserted = 0
    corpus.list_of_rows.each do |row|
      begin
        database.insert(row.table, row.rowid.try(&.to_i64), SQLiteEngineWriteDriver.values(row.list_of_values))
        inserted += 1
      rescue error : Grant::SQLiteEngine::UnsupportedSQL
        skipped << row.table
      end
    end
    tables = database.schema.list_of_tables.size
    # sqlite3 built its file with INSERT OR IGNORE, and an ignored row still
    # raises an AUTOINCREMENT counter; the engine is given only the rows
    # sqlite3 kept, so sqlite_sequence is left out of the comparison.
    skipped_objects = Set{"sqlite_sequence"}
    database.schema.list_of_entries.each do |entry|
      skipped_objects << entry.object_name if skipped.includes?(entry.table_name)
    end
    database.close
    SQLiteEngineWriteDriver.ruby(["verify", directory.to_s, "e"])
    STDOUT.puts "\n  corpus writes: #{corpus.list_of_statements.size} CREATE statements, #{created} accepted by the engine " \
                "(#{corpus.manifest.create_statements_accepted} by sqlite3), #{tables} tables, #{inserted} of #{corpus.list_of_rows.size} rows inserted; " \
                "tables needing SQL evaluation (expression or partial indexes): #{skipped.to_a.sort.join(", ")}"
    list_of_disagreements.each { |message| STDOUT.puts "  #{message}" }
    list_of_rejections.tally.each { |message, times| STDOUT.puts "  rejected #{times}x: #{message}" }
    File.read(directory / "grant_corpus_schema.e.integrity").should eq("ok\n")
    list_of_disagreements.should be_empty
    created.should eq(corpus.manifest.create_statements_accepted)
    File.read(directory / "grant_corpus_schema.e.schema").should eq(File.read(directory / "grant_corpus_schema.schema"))
    expected = SQLiteEngineCorpusWrites.without(File.read(directory / "grant_corpus_schema.expected"), skipped_objects)
    SQLiteEngineWriteDriver.first_difference(expected, SQLiteEngineCorpusWrites.without(File.read(directory / "grant_corpus_schema.e.expected"), skipped_objects)).should be_nil
    SQLiteEngineWriteDriver.first_difference(expected, SQLiteEngineCorpusWrites.without(SQLiteEngineWriteDriver.engine_dump(path), skipped_objects)).should be_nil
    FileUtils.rm_rf(directory)
  end
end
