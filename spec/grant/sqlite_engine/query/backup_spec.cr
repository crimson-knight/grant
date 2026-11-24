require "spec"
require "file_utils"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../../src/grant/drivers/sqlite3/libsqlite3"

# Copies databases with `Engine::Database#backup_to` and `VACUUM INTO`
# through Grant's engine and libsqlite3, in every pairing of the two, and
# compares what the target file holds with what the source holds.
private module BackupDifferential
  alias Engine = Grant::SQLite3::Engine

  ENGINES = {"grant" => Engine::GrantEngine.new.as(Engine), "c" => Engine::LibSQLite3Engine.new.as(Engine)}

  SETUP = <<-SQL
    CREATE TABLE authors(id INTEGER PRIMARY KEY, first_name TEXT NOT NULL, email TEXT UNIQUE, born_at TEXT);
    CREATE TABLE posts(id INTEGER PRIMARY KEY AUTOINCREMENT, author_id INTEGER REFERENCES authors(id), title TEXT DEFAULT 'untitled',
      body TEXT, score REAL, picture BLOB, word_count INTEGER GENERATED ALWAYS AS (length(body)) STORED);
    CREATE TABLE settings(setting_key TEXT PRIMARY KEY, setting_value) WITHOUT ROWID;
    CREATE INDEX index_posts_on_author_id ON posts(author_id);
    CREATE INDEX index_posts_on_score_and_title ON posts(score DESC, title COLLATE NOCASE);
    CREATE UNIQUE INDEX index_authors_on_lower_email ON authors(lower(email));
    CREATE VIEW post_titles AS SELECT id, title FROM posts;
    INSERT INTO authors VALUES (1, 'Ada', 'ada@example.com', '1815-12-10');
    INSERT INTO authors VALUES (2, 'Brian', 'bk@example.com', NULL);
    INSERT INTO posts(author_id, title, body, score, picture) VALUES (1, 'Hello World', 'abcdef', 1.5, x'00ff10');
    INSERT INTO posts(author_id, title, body, score) VALUES (2, 'Second Post', NULL, NULL);
    INSERT INTO posts(author_id, body) VALUES (2, 'a body long enough to need overflow pages: ' || hex(zeroblob(6000)));
    DELETE FROM posts WHERE id = 2;
    INSERT INTO settings VALUES ('theme', 'dark'), ('volume', 11);
    PRAGMA user_version = 42;
    PRAGMA application_id = 1196573268;
    SQL

  def self.open(engine : Engine, path : String) : Engine::Database
    code, database = engine.open(path)
    raise "open #{path} failed (#{code}): #{database.error_message}" unless code == Engine::OK_CODE
    database
  end

  def self.exec(database : Engine::Database, sql : String) : Nil
    code = database.exec(sql)
    raise "#{sql.lines.first} failed (#{code}): #{database.error_message}" unless code == Engine::OK_CODE
  end

  # The result code, message and rows of one statement.
  def self.outcome(database : Engine::Database, sql : String) : String
    code, statement = database.prepare(sql)
    return "code=#{code} #{database.error_message}" unless code == Engine::OK_CODE
    list_of_rows = [] of Array(String)
    step = Engine::ROW_CODE
    loop do
      step = statement.step
      break unless step == Engine::ROW_CODE
      list_of_rows << (0...statement.column_count).map do |column|
        case statement.column_type(column)
        when Grant::SQLite3::Type::INTEGER then "i:#{statement.column_int64(column)}"
        when Grant::SQLite3::Type::FLOAT   then "r:#{statement.column_double(column)}"
        when Grant::SQLite3::Type::NULL    then "null"
        when Grant::SQLite3::Type::BLOB    then "b:#{statement.column_blob(column).hexstring}"
        else                                    "t:#{statement.column_text(column)}"
        end
      end
    end
    message = step == Engine::DONE_CODE ? "" : database.error_message
    statement.finalize_statement
    "code=#{step} #{message} #{list_of_rows}"
  end

  # What the C library reads from the file at *path*: the integrity check,
  # the schema, every table's rows, sqlite_sequence and the two header
  # numbers.
  def self.content(path : String) : Array(String)
    database = open(ENGINES["c"], path)
    begin
      list = ["PRAGMA integrity_check", "PRAGMA user_version", "PRAGMA application_id",
              "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"].map { |sql| "#{sql} => #{outcome(database, sql)}" }
      names = outcome(database, "SELECT name FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name")
      names.scan(/"t:([^"]+)"/) do |match|
        sql = %(SELECT * FROM "#{match[1]}" ORDER BY 1, 2)
        list << "#{sql} => #{outcome(database, sql)}"
      end
      list
    ensure
      database.close
    end
  end

  # What /usr/bin/sqlite3 prints for the file: the integrity check and the
  # whole dump.
  def self.shell_dump(path : String) : String
    output = IO::Memory.new
    Process.run("/usr/bin/sqlite3", [path, "PRAGMA integrity_check; PRAGMA user_version; PRAGMA application_id;", ".dump"], output: output, error: output)
    output.to_s
  end

  def self.in_directory(name : String, & : String ->) : Nil
    directory = File.tempname(name)
    Dir.mkdir_p(directory)
    begin
      yield directory
    ensure
      File.chmod(directory, 0o700)
      FileUtils.rm_rf(directory)
    end
  end

  def self.each_pairing(& : String, Engine, Engine ->) : Nil
    ENGINES.each do |source_label, source_engine|
      ENGINES.each do |target_label, target_engine|
        yield "#{source_label} to #{target_label}", source_engine, target_engine
      end
    end
  end

  # One generated database: tables of random shape with random rows, some
  # deleted again so the file has free pages, some indexed, sometimes a
  # view, an AUTOINCREMENT table, header numbers.
  def self.random_setup(random : Random) : String
    String.build do |sql|
      table_count = random.rand(1..4)
      table_count.times do |table|
        column_count = random.rand(1..5)
        columns = (0...column_count).map { |column| "c#{column} #{%w[INTEGER TEXT REAL BLOB NUMERIC].sample(random)}" }
        key = random.rand(4)
        if key == 0
          sql << "CREATE TABLE t#{table}(id INTEGER PRIMARY KEY AUTOINCREMENT, #{columns.join(", ")});\n"
        elsif key == 1
          sql << "CREATE TABLE t#{table}(id INTEGER PRIMARY KEY, #{columns.join(", ")}) WITHOUT ROWID;\n"
        else
          sql << "CREATE TABLE t#{table}(id INTEGER PRIMARY KEY, #{columns.join(", ")});\n"
        end
        sql << "CREATE INDEX index_t#{table}_on_c0 ON t#{table}(c0);\n" if random.rand(2) == 0
        row_count = random.rand(0..40)
        row_count.times do |row|
          values = (0...column_count).map { random_literal(random) }
          sql << "INSERT INTO t#{table}(id, #{(0...column_count).map { |column| "c#{column}" }.join(", ")}) VALUES (#{row + 1}, #{values.join(", ")});\n"
        end
        sql << "DELETE FROM t#{table} WHERE id % #{random.rand(2..5)} = 0;\n" if random.rand(3) == 0
        sql << "CREATE VIEW v#{table} AS SELECT id, c0 FROM t#{table};\n" if random.rand(4) == 0
      end
      sql << "PRAGMA user_version = #{random.rand(0..100_000)};\n"
      sql << "PRAGMA application_id = #{random.rand(0..100_000)};\n" if random.rand(2) == 0
    end
  end

  def self.random_literal(random : Random) : String
    case random.rand(6)
    when 0 then "NULL"
    when 1 then random.rand(-1_000_000..1_000_000).to_s
    when 2 then (random.rand(-1_000_000..1_000_000) / 64.0).to_s
    when 3 then "'#{random.hex(random.rand(0..12))}'"
    when 4 then "x'#{random.hex(random.rand(0..12))}'"
    else        "'long #{random.hex(8) * random.rand(1..700)}'"
    end
  end
end

describe "Grant::SQLite3::Engine::Database#backup_to" do
  BackupDifferential.each_pairing do |pairing, source_engine, target_engine|
    it "copies schema, rows, sqlite_sequence, user_version and application_id (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        source_path = File.join(directory, "source.db")
        target_path = File.join(directory, "target.db")
        source = BackupDifferential.open(source_engine, source_path)
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(source, BackupDifferential::SETUP)
        source.backup_to(target).should eq(0)
        # The open target connection reads the copy and writes on from it.
        BackupDifferential.outcome(target, "SELECT first_name FROM authors ORDER BY id").should eq(%(code=101  [["t:Ada"], ["t:Brian"]]))
        BackupDifferential.outcome(target, "SELECT seq FROM sqlite_sequence WHERE name = 'posts'").should eq(%(code=101  [["i:3"]]))
        source.close
        target.close
        BackupDifferential.content(target_path).should eq(BackupDifferential.content(source_path))
        dump = BackupDifferential.shell_dump(target_path)
        dump.lines.first(3).should eq(["ok", "42", "1196573268"])
        dump.should eq(BackupDifferential.shell_dump(source_path))

        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(target, "INSERT INTO posts(author_id, body) VALUES (1, 'after the copy')")
        BackupDifferential.outcome(target, "SELECT max(id), count(*) FROM posts").should eq(%(code=101  [["i:4", "i:3"]]))
        target.close
        BackupDifferential.shell_dump(target_path).lines.first.should eq("ok")
      end
    end

    it "replaces what the target held, larger or smaller (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        source_path = File.join(directory, "source.db")
        target_path = File.join(directory, "target.db")
        source = BackupDifferential.open(source_engine, source_path)
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(source, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, 'kept')")
        BackupDifferential.exec(target, BackupDifferential::SETUP)
        BackupDifferential.outcome(target, "SELECT count(*) FROM posts").should eq(%(code=101  [["i:2"]]))
        source.backup_to(target).should eq(0)
        BackupDifferential.outcome(target, "SELECT count(*) FROM posts").should start_with("code=1 no such table: posts")
        BackupDifferential.outcome(target, "SELECT body FROM notes").should eq(%(code=101  [["t:kept"]]))
        source.close
        target.close
        File.size(target_path).should eq(File.size(source_path))
        BackupDifferential.shell_dump(target_path).should eq(BackupDifferential.shell_dump(source_path))

        # And back the other way: the small file grows again.
        source = BackupDifferential.open(source_engine, source_path)
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(source, BackupDifferential::SETUP)
        source.backup_to(target).should eq(0)
        source.close
        target.close
        BackupDifferential.shell_dump(target_path).should eq(BackupDifferential.shell_dump(source_path))
      end
    end

    it "copies between a file and an in-memory database (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        path = File.join(directory, "saved.db")
        memory = BackupDifferential.open(source_engine, ":memory:")
        saved = BackupDifferential.open(target_engine, path)
        BackupDifferential.exec(memory, BackupDifferential::SETUP)
        memory.backup_to(saved).should eq(0)
        saved.close
        BackupDifferential.shell_dump(path).lines.first(3).should eq(["ok", "42", "1196573268"])
        restored = BackupDifferential.open(source_engine, ":memory:")
        saved = BackupDifferential.open(target_engine, path)
        saved.backup_to(restored).should eq(0)
        list_of_queries = ["SELECT * FROM authors ORDER BY id", "SELECT id, title, word_count FROM posts ORDER BY id",
                           "SELECT * FROM settings ORDER BY 1", "SELECT * FROM sqlite_sequence", "PRAGMA user_version", "SELECT * FROM post_titles ORDER BY id"]
        list_of_queries.each do |sql|
          BackupDifferential.outcome(restored, sql).should eq(BackupDifferential.outcome(memory, sql))
        end
        [memory, saved, restored].each(&.close)
      end
    end

    it "copies a WAL-mode source and into a WAL-mode target (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        source_path = File.join(directory, "source.db")
        target_path = File.join(directory, "target.db")
        source = BackupDifferential.open(source_engine, source_path)
        BackupDifferential.exec(source, "PRAGMA journal_mode = WAL")
        BackupDifferential.exec(source, BackupDifferential::SETUP)
        target = BackupDifferential.open(target_engine, target_path)
        source.backup_to(target).should eq(0)
        BackupDifferential.outcome(target, "PRAGMA journal_mode").should eq(%(code=101  [["t:wal"]]))
        BackupDifferential.exec(target, "INSERT INTO authors VALUES (3, 'Cy', NULL, NULL)")
        expected = BackupDifferential.outcome(source, "SELECT * FROM posts ORDER BY id")
        BackupDifferential.outcome(target, "SELECT * FROM posts ORDER BY id").should eq(expected)
        target.close
        BackupDifferential.shell_dump(target_path).lines.first(3).should eq(["ok", "42", "1196573268"])

        # A rollback-journal source over the WAL-mode target leaves it in WAL mode.
        plain_path = File.join(directory, "plain.db")
        plain = BackupDifferential.open(source_engine, plain_path)
        BackupDifferential.exec(plain, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, 'kept')")
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.outcome(target, "PRAGMA journal_mode").should eq(%(code=101  [["t:wal"]]))
        plain.backup_to(target).should eq(0)
        BackupDifferential.outcome(target, "PRAGMA journal_mode").should eq(%(code=101  [["t:wal"]]))
        BackupDifferential.outcome(target, "SELECT body FROM notes").should eq(%(code=101  [["t:kept"]]))
        [source, plain, target].each(&.close)
        BackupDifferential.content(target_path).should eq(BackupDifferential.content(plain_path))
      end
    end

    it "copies a source of another page size over a filled target (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        source_path = File.join(directory, "source.db")
        target_path = File.join(directory, "target.db")
        # Only the C library sets a page size; the source engine then opens the file.
        small_pages = BackupDifferential.open(BackupDifferential::ENGINES["c"], source_path)
        BackupDifferential.exec(small_pages, "PRAGMA page_size = 1024")
        BackupDifferential.exec(small_pages, BackupDifferential::SETUP)
        small_pages.close
        source = BackupDifferential.open(source_engine, source_path)
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(target, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, hex(zeroblob(20000)))")
        source.backup_to(target).should eq(0)
        BackupDifferential.outcome(target, "SELECT first_name FROM authors ORDER BY id").should eq(%(code=101  [["t:Ada"], ["t:Brian"]]))
        BackupDifferential.outcome(target, "PRAGMA page_size").should eq(%(code=101  [["i:1024"]]))
        source.close
        target.close
        File.size(target_path).should eq(File.size(source_path))
        BackupDifferential.shell_dump(target_path).should eq(BackupDifferential.shell_dump(source_path))
      end
    end

    it "returns a code and leaves C's message on the target when the copy cannot happen (#{pairing})" do
      BackupDifferential.in_directory("backup-spec") do |directory|
        source = BackupDifferential.open(source_engine, File.join(directory, "source.db"))
        BackupDifferential.exec(source, BackupDifferential::SETUP)

        busy_path = File.join(directory, "busy.db")
        busy = BackupDifferential.open(target_engine, busy_path)
        BackupDifferential.exec(busy, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); BEGIN; INSERT INTO notes VALUES (1, 'mine')")
        source.backup_to(busy).should eq(1)
        busy.error_message.should eq("destination database is in use")
        BackupDifferential.exec(busy, "COMMIT")
        BackupDifferential.outcome(busy, "SELECT body FROM notes").should eq(%(code=101  [["t:mine"]]))
        busy.close

        # A writer in another connection holds the target.
        other = BackupDifferential.open(target_engine, busy_path)
        busy = BackupDifferential.open(target_engine, busy_path)
        BackupDifferential.exec(other, "BEGIN IMMEDIATE")
        source.backup_to(busy).should eq(5)
        busy.error_message.should eq("database is locked")
        BackupDifferential.exec(other, "ROLLBACK")
        [other, busy].each(&.close)
        BackupDifferential.content(busy_path).join.should contain("mine")

        # The target's folder takes no journal file.
        locked_directory = File.join(directory, "locked")
        Dir.mkdir(locked_directory)
        unwritable_path = File.join(locked_directory, "target.db")
        unwritable = BackupDifferential.open(target_engine, unwritable_path)
        BackupDifferential.exec(unwritable, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); INSERT INTO notes VALUES (1, 'mine')")
        File.chmod(locked_directory, 0o500)
        begin
          source.backup_to(unwritable).should eq(1544)
          unwritable.error_message.should eq("attempt to write a readonly database")
        ensure
          File.chmod(locked_directory, 0o700)
        end
        unwritable.close
        BackupDifferential.content(unwritable_path).join.should contain("mine")
        source.close
      end
    end
  end

  BackupDifferential::ENGINES.each do |label, engine|
    it "refuses to copy a database over itself (#{label})" do
      database = BackupDifferential.open(engine, ":memory:")
      BackupDifferential.exec(database, "CREATE TABLE notes(id INTEGER PRIMARY KEY)")
      database.backup_to(database).should eq(1)
      database.error_message.should eq("source and destination must be distinct")
      database.close
    end
  end

  it "copies a source whose table has a VIRTUAL generated column" do
    BackupDifferential.in_directory("backup-spec") do |directory|
      source_path = File.join(directory, "source.db")
      made_by_c = BackupDifferential.open(BackupDifferential::ENGINES["c"], source_path)
      BackupDifferential.exec(made_by_c, "CREATE TABLE lines(id INTEGER PRIMARY KEY, quantity INTEGER, price REAL, total REAL GENERATED ALWAYS AS (quantity * price) VIRTUAL);" \
                                         "CREATE INDEX index_lines_on_total ON lines(total); INSERT INTO lines(quantity, price) VALUES (2, 1.5), (3, 4.0)")
      made_by_c.close
      BackupDifferential::ENGINES.each do |label, target_engine|
        target_path = File.join(directory, "target-#{label}.db")
        source = BackupDifferential.open(BackupDifferential::ENGINES["grant"], source_path)
        target = BackupDifferential.open(target_engine, target_path)
        source.backup_to(target).should eq(0)
        [source, target].each(&.close)
        BackupDifferential.content(target_path).should eq(BackupDifferential.content(source_path))
        BackupDifferential.shell_dump(target_path).should eq(BackupDifferential.shell_dump(source_path))
      end
      BackupDifferential.content(source_path).join.should contain(%(["i:2", "i:3", "r:4.0", "r:12.0"]))
    end
  end

  it "returns the open failure of a target that never opened" do
    BackupDifferential.in_directory("backup-spec") do |directory|
      code, never_opened = BackupDifferential::ENGINES["grant"].open(File.join(directory, "missing-folder", "target.db"))
      code.should eq(14)
      BackupDifferential::ENGINES.each_value do |source_engine|
        source = BackupDifferential.open(source_engine, ":memory:")
        BackupDifferential.exec(source, BackupDifferential::SETUP)
        source.backup_to(never_opened).should eq(14)
        never_opened.error_message.should_not eq("not an error")
        source.close
      end
    end
  end

  it "answers busy while the source has a write transaction open, as C does" do
    list_of_outcomes = BackupDifferential::ENGINES.map do |_label, engine|
      source = BackupDifferential.open(engine, ":memory:")
      target = BackupDifferential.open(engine, ":memory:")
      BackupDifferential.exec(source, "CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT); BEGIN; INSERT INTO notes VALUES (1, 'uncommitted')")
      code = source.backup_to(target)
      BackupDifferential.exec(source, "ROLLBACK")
      result = "#{code} #{BackupDifferential.outcome(target, "SELECT * FROM notes")} #{BackupDifferential.outcome(source, "SELECT * FROM notes")}"
      [source, target].each(&.close)
      result
    end
    list_of_outcomes[0].should eq(list_of_outcomes[1])
  end

  it "leaves an empty database where an empty source was copied" do
    BackupDifferential.each_pairing do |_pairing, source_engine, target_engine|
      BackupDifferential.in_directory("backup-spec") do |directory|
        target_path = File.join(directory, "target.db")
        source = BackupDifferential.open(source_engine, ":memory:")
        target = BackupDifferential.open(target_engine, target_path)
        BackupDifferential.exec(target, BackupDifferential::SETUP)
        source.backup_to(target).should eq(0)
        BackupDifferential.outcome(target, "SELECT count(*) FROM sqlite_master").should eq(%(code=101  [["i:0"]]))
        BackupDifferential.exec(target, "CREATE TABLE notes(id INTEGER PRIMARY KEY)")
        [source, target].each(&.close)
        BackupDifferential.shell_dump(target_path).lines.first(3).should eq(["ok", "0", "0"])
      end
    end
  end
end

describe "VACUUM INTO" do
  it "writes a file sqlite3 accepts with the same schema and rows" do
    BackupDifferential::ENGINES.each do |label, engine|
      ["PRAGMA journal_mode = DELETE", "PRAGMA journal_mode = WAL"].each do |journal_mode|
        BackupDifferential.in_directory("vacuum-into-spec") do |directory|
          source_path = File.join(directory, "source.db")
          source = BackupDifferential.open(engine, source_path)
          BackupDifferential.exec(source, journal_mode)
          BackupDifferential.exec(source, BackupDifferential::SETUP)
          copy_path = File.join(directory, "copy.db")
          BackupDifferential.outcome(source, "VACUUM INTO '#{copy_path}'").should eq("code=101  []")
          parameter_path = File.join(directory, "parameter.db")
          code, statement = source.prepare("VACUUM main INTO ? || '.db'")
          code.should eq(0)
          statement.bind_text(1, parameter_path.rchop(".db"))
          statement.step.should eq(101)
          statement.finalize_statement
          source.close
          [copy_path, parameter_path].each do |path|
            BackupDifferential.content(path).should eq(BackupDifferential.content(source_path))
            dump = BackupDifferential.shell_dump(path)
            dump.lines.first(3).should eq(["ok", "42", "1196573268"])
            dump.should eq(BackupDifferential.shell_dump(source_path))
            # The copy is a rollback-journal database whatever the source's mode.
            File.read(path).to_slice[18, 2].should eq(Bytes[1, 1])
            Dir.children(directory).select(&.starts_with?(File.basename(path))).should eq([File.basename(path)])
          end
          "#{label} checked".should_not be_empty
        end
      end
    end
  end

  it "reports the same code and message as C for each refusal" do
    list_of_outcomes = BackupDifferential::ENGINES.map do |_label, engine|
      results = [] of String
      BackupDifferential.in_directory("vacuum-into-spec") do |directory|
        database = BackupDifferential.open(engine, File.join(directory, "source.db"))
        BackupDifferential.exec(database, BackupDifferential::SETUP)
        taken_path = File.join(directory, "taken.db")
        empty_path = File.join(directory, "empty.db")
        File.write(taken_path, "x")
        File.write(empty_path, "")
        one_byte_path = File.join(directory, "one-byte.db")
        File.write(one_byte_path, "x")
        File.write(taken_path, "xy")
        list_of_statements = [
          "VACUUM INTO '#{taken_path}'",
          "VACUUM INTO '#{empty_path}'",
          "VACUUM INTO '#{one_byte_path}'",
          "VACUUM INTO '#{empty_path}'",
          "VACUUM INTO 5",
          "VACUUM INTO NULL",
          "VACUUM INTO x'6162'",
          "VACUUM INTO first_name",
          "VACUUM nowhere INTO '#{File.join(directory, "nowhere.db")}'",
          "VACUUM INTO '#{File.join(directory, "missing-folder", "copy.db")}'",
          "VACUUM INTO ''",
          "VACUUM INTO ':memory:'",
          "BEGIN",
          "VACUUM INTO '#{File.join(directory, "inside.db")}'",
          "ROLLBACK",
          "VACUUM",
          "VACUUM main",
          "SELECT count(*) FROM posts",
        ]
        list_of_statements.each do |sql|
          results << "#{sql} => #{BackupDifferential.outcome(database, sql)}".gsub(directory, "DIR")
        end
        database.close
        results << Dir.children(directory).sort!.join(" ")
        results << BackupDifferential.content(empty_path).join("\n")
      end
      results
    end
    grant, c = list_of_outcomes
    grant.zip(c).each { |ours, theirs| ours.should eq(theirs) }
  end
end

describe "backup and VACUUM INTO, seeded random differential" do
  it "copies generated databases in every pairing with nothing different" do
    random = Random.new(20261124)
    iterations = (ENV["GRANT_BACKUP_DIFFERENTIAL_ITERATIONS"]? || "2000").to_i
    list_of_pairings = [] of {String, BackupDifferential::Engine, BackupDifferential::Engine}
    BackupDifferential.each_pairing { |pairing, source_engine, target_engine| list_of_pairings << {pairing, source_engine, target_engine} }
    counts = Hash(String, Int32).new(0)
    differences = [] of String
    BackupDifferential.in_directory("backup-random") do |directory|
      iterations.times do |iteration|
        pairing, source_engine, target_engine = list_of_pairings[iteration % list_of_pairings.size]
        source_path = File.join(directory, "source-#{iteration}.db")
        target_path = File.join(directory, "target-#{iteration}.db")
        setup = BackupDifferential.random_setup(random)
        page_size = [512, 1024, 4096, 4096, 8192].sample(random)
        wal = random.rand(4) == 0
        filled_target = random.rand(3) == 0
        vacuum_into = !filled_target && random.rand(4) == 0
        if page_size != 4096
          sized = BackupDifferential.open(BackupDifferential::ENGINES["c"], source_path)
          BackupDifferential.exec(sized, "PRAGMA page_size = #{page_size}; CREATE TABLE sized(id INTEGER PRIMARY KEY)")
          sized.close
        end
        source = BackupDifferential.open(source_engine, source_path)
        BackupDifferential.exec(source, "PRAGMA journal_mode = WAL") if wal
        BackupDifferential.exec(source, setup)
        kind = vacuum_into ? "vacuum into (#{pairing.split.first})" : "backup #{pairing}"
        if vacuum_into
          result = BackupDifferential.outcome(source, "VACUUM INTO '#{target_path}'")
          differences << "#{iteration} #{kind}: #{result}" unless result == "code=101  []"
        else
          target = BackupDifferential.open(target_engine, target_path)
          BackupDifferential.exec(target, BackupDifferential.random_setup(random)) if filled_target
          code = source.backup_to(target)
          differences << "#{iteration} #{kind}: code #{code} #{target.error_message}" unless code == 0
          target.close
        end
        source.close
        expected = BackupDifferential.content(source_path)
        actual = BackupDifferential.content(target_path)
        unless actual == expected && expected.first.ends_with?(%([["t:ok"]]))
          differences << "#{iteration} #{kind} page_size=#{page_size} wal=#{wal} filled=#{filled_target}: #{actual.zip?(expected).find { |ours, theirs| ours != theirs }.to_s[0, 400]} #{expected.first[0, 300]}"
        end
        counts[kind] += 1
        Dir.children(directory).each { |name| File.delete(File.join(directory, name)) }
      end
    end
    summary = "backup random differential: seed 20261124, #{iterations} databases, #{differences.size} differences; #{counts.to_a.sort_by!(&.first).map { |kind, count| "#{kind} #{count}" }.join(", ")}"
    if summary_path = ENV["GRANT_BACKUP_DIFFERENTIAL_SUMMARY"]?
      File.write(summary_path, summary + "\n" + differences.join("\n") + "\n")
    end
    differences.first(5).should eq([] of String)
    counts.size.should eq(6)
  end
end
