require "./support/differential"

private def sqlite3_scalar(path : Path, sql : String) : String
  output = IO::Memory.new
  status = Process.run("sqlite3", [path.to_s, sql], output: output)
  raise "sqlite3 failed on #{path}" unless status.success?
  output.to_s.strip
end

describe "Grant::SQLiteEngine structures" do
  directory, _manifest = SQLiteEngineDifferential.generate("standard")

  describe "the header" do
    it "reads the page size and the text encoding" do
      [512, 4096, 65_536].each do |page_size|
        database = Grant::SQLiteEngine::Database.open(directory / "page_size_#{page_size}.db")
        database.header.try(&.page_size).should eq(page_size)
        database.close
      end
      {"utf8" => "UTF8", "utf16le" => "UTF16LE", "utf16be" => "UTF16BE"}.each do |label, encoding|
        database = Grant::SQLiteEngine::Database.open(directory / "encoding_#{label}.db")
        database.text_encoding.to_s.should eq(encoding)
        database.close
      end
    end
  end

  describe "#find_row" do
    it "finds rows by rowid by descending the b-tree" do
      database = Grant::SQLiteEngine::Database.open(directory / "rows_200000.db")
      rows = database.rows("items")
      rows.size.should eq(200_000)
      [1_i64, 2_i64, 777_i64, 123_456_i64, 200_000_i64].each do |rowid|
        found = database.find_row("items", rowid)
        found.should_not be_nil
        found.try(&.values).should eq(rows[rowid - 1].values)
      end
      database.find_row("items", 0_i64).should be_nil
      database.find_row("items", 200_001_i64).should be_nil
      database.close
    end
  end

  describe "#freelist" do
    it "lists as many free pages as C SQLite counts" do
      path = directory / "freelist.db"
      database = Grant::SQLiteEngine::Database.open(path)
      freelist = database.freelist
      freelist.page_count.should eq(sqlite3_scalar(path, "PRAGMA freelist_count").to_i)
      freelist.list_of_leaf_pages.size.should be > 100
      database.close
    end
  end

  describe "#pointer_map_entries" do
    it "records a root-page entry for every b-tree root after page 1" do
      %w(auto_vacuum_full auto_vacuum_incremental).each do |fixture|
        path = directory / "#{fixture}.db"
        database = Grant::SQLiteEngine::Database.open(path)
        entries = database.pointer_map_entries
        roots = entries.select(&.entry_type.root_page?).map(&.page_number).sort!
        expected = sqlite3_scalar(path, "SELECT group_concat(rootpage) FROM (SELECT rootpage FROM sqlite_schema WHERE rootpage > 1 ORDER BY rootpage)")
        roots.join(',').should eq(expected)
        entries.count(&.entry_type.free_page?).should eq(database.freelist.page_count)
        database.close
      end
      database = Grant::SQLiteEngine::Database.open(directory / "auto_vacuum_none.db")
      database.pointer_map_entries.should be_empty
      database.close
    end
  end

  describe "the WAL" do
    it "drops frames after the last commit and frames of an older generation" do
      %w(wal_torn_tail wal_restarted).each do |fixture|
        SQLiteEngineDifferential.compare(directory, fixture).first_difference.should be_nil
      end
      database = Grant::SQLiteEngine::Database.open(directory / "wal_restarted.db")
      database.rows("events").size.should eq(401)
      database.close
    end
  end

  describe "a VIRTUAL generated column" do
    it "raises UnsupportedSQL naming the column" do
      path = Path[Dir.tempdir] / "grant-sqlite-engine-virtual-#{Process.pid}.db"
      File.delete?(path)
      Process.run("sqlite3", [path.to_s, "CREATE TABLE t(a INTEGER, b INTEGER AS (a * 2) VIRTUAL); INSERT INTO t(a) VALUES (1);"])
      database = Grant::SQLiteEngine::Database.open(path)
      expect_raises(Grant::SQLiteEngine::UnsupportedSQL, /VIRTUAL generated column t\.b/) { database.rows("t") }
      database.close
      File.delete?(path)
    end
  end
end
