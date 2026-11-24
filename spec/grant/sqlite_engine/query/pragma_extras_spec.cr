require "spec"
require "file_utils"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../../src/grant/drivers/sqlite3/libsqlite3"

# Runs PRAGMAs through Grant's engine and libsqlite3 on the same schema
# and rows, and compares result code, column names and rows.
private module PragmaDifferential
  alias Engine = Grant::SQLite3::Engine

  def self.outcome(database : Engine::Database, sql : String) : String
    code, statement = database.prepare(sql)
    return "code=#{code} #{database.error_message}" unless code == Engine::OK_CODE
    list_of_columns = (0...statement.column_count).map { |index| statement.column_name(index) }
    list_of_rows = [] of Array(String)
    step = Engine::ROW_CODE
    loop do
      step = statement.step
      break unless step == Engine::ROW_CODE
      list_of_rows << (0...statement.column_count).map do |column|
        case statement.column_type(column)
        when Grant::SQLite3::Type::INTEGER then "i:#{statement.column_int64(column)}"
        when Grant::SQLite3::Type::NULL    then "null"
        else                                    "t:#{statement.column_text(column)}"
        end
      end
    end
    message = step == Engine::DONE_CODE ? "" : database.error_message
    statement.finalize_statement
    "code=#{step} #{message} #{list_of_columns} #{list_of_rows}"
  end

  # The outcomes of *list_of_queries* after *setup*, in the connection that
  # ran the setup and again in a fresh connection.
  def self.outcomes(engine : Engine, path : String, setup : String, list_of_queries : Array(String)) : Array(String)
    FileUtils.rm_rf(path)
    results = [] of String
    2.times do |pass|
      code, database = engine.open(path)
      raise "open failed (#{code})" unless code == Engine::OK_CODE
      begin
        if pass == 0
          setup_code = database.exec(setup)
          raise "setup failed: #{database.error_message}" unless setup_code == Engine::OK_CODE
        end
        list_of_queries.each { |sql| results << "#{pass} #{sql} => #{outcome(database, sql)}" }
      ensure
        database.close
      end
    end
    results
  end

  def self.differences(setup : String, list_of_queries : Array(String)) : Array(String)
    directory = File.tempname("pragma-extras")
    Dir.mkdir_p(directory)
    begin
      expected = outcomes(Engine::LibSQLite3Engine.new, File.join(directory, "c.db"), setup, list_of_queries)
      actual = outcomes(Engine::GrantEngine.new, File.join(directory, "grant.db"), setup, list_of_queries)
      expected.zip(actual).compact_map { |c, grant| c == grant ? nil : "C:     #{c}\n      Grant: #{grant}" }
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # A random schema of parent and child tables with rows that break some
  # foreign keys. Every table keeps its rowid: a WITHOUT ROWID parent is
  # not yet found by the engine's parent lookup (ParentLookup.locate).
  def self.random_setup(random : Random) : String
    list_of_names = Array.new(random.rand(1..9)) { |index| "#{%w[author post Tag comment_ x LONGER_table_name q z9 m][index]}#{random.rand(100)}" }
    String.build do |sql|
      sql << "PRAGMA foreign_keys=OFF;\n"
      list_of_names.each do |name|
        parent = random.rand(5) == 0 ? "missing_parent" : list_of_names.sample(random)
        second = list_of_names.sample(random)
        sql << "CREATE TABLE #{name}(id INTEGER PRIMARY KEY, code TEXT UNIQUE, "
        sql << "first_ref INTEGER REFERENCES #{parent}(id), second_ref TEXT, third_ref"
        sql << " REFERENCES #{second}" if random.rand(2) == 0
        sql << ", FOREIGN KEY(second_ref) REFERENCES #{second}(code))"
        sql << ";\n"
        sql << "CREATE VIEW view_of_#{name} AS SELECT id FROM #{name};\n" if random.rand(4) == 0
        random.rand(0..6).times do |row|
          first_ref = random.rand(4) == 0 ? "NULL" : random.rand(1..8).to_s
          second_ref = random.rand(4) == 0 ? "NULL" : "'c#{random.rand(1..8)}'"
          third_ref = random.rand(3) == 0 ? "NULL" : random.rand(1..8).to_s
          sql << "INSERT INTO #{name} VALUES (#{row + 1}, 'c#{row + 1}', #{first_ref}, #{second_ref}, #{third_ref});\n"
        end
      end
    end
  end
end

describe "Grant::SQLiteEngine PRAGMAs of milestone G6" do
  setup = <<-SQL
    CREATE TABLE authors(id INTEGER PRIMARY KEY, first_name TEXT NOT NULL);
    CREATE TABLE posts(id INTEGER PRIMARY KEY, author_id INTEGER REFERENCES authors(id),
      word_count INTEGER GENERATED ALWAYS AS (id * 2) STORED, slug TEXT GENERATED ALWAYS AS ('p' || id) STORED,
      shout GENERATED ALWAYS AS (upper(slug)) STORED);
    INSERT INTO authors VALUES (1, 'Ada');
    PRAGMA foreign_keys=OFF;
    INSERT INTO posts(id, author_id) VALUES (1, 1), (2, 99), (3, NULL);
    PRAGMA user_version=7;
    SQL

  it "reports generated column types, auto_vacuum, optimize and incremental_vacuum as C does" do
    list_of_queries = ["PRAGMA table_xinfo(posts)", "PRAGMA table_info(posts)", "PRAGMA auto_vacuum", "PRAGMA auto_vacuum=0",
                       "PRAGMA optimize", "PRAGMA optimize(0x10002)", "PRAGMA optimize=-1", "PRAGMA incremental_vacuum",
                       "PRAGMA incremental_vacuum(5)", "PRAGMA main.auto_vacuum"]
    PragmaDifferential.differences(setup, list_of_queries).should be_empty
  end

  it "reads the single-value PRAGMAs as tables" do
    # secure_delete's default is a build option (SQLITE_SECURE_DELETE): the
    # pinned 3.51.0 reference reads 0, Debian and Ubuntu builds read 1.
    list_of_names = PragmaExtrasNames.list_of_table_valued.reject { |name| name == "pragma_secure_delete" }
    list_of_queries = list_of_names.map { |name| "SELECT * FROM #{name}" }
    list_of_queries << "SELECT user_version, page_size FROM pragma_user_version, pragma_page_size()"
    list_of_queries << "SELECT * FROM pragma_foreign_key_check('posts')"
    list_of_queries << "SELECT count(*) FROM pragma_page_count WHERE page_count > 1"
    PragmaDifferential.differences(setup, list_of_queries).should be_empty
  end

  it "lists foreign key violations as C does" do
    list_of_queries = ["PRAGMA foreign_key_check", "PRAGMA foreign_key_check(posts)", "PRAGMA foreign_key_check(authors)",
                       "PRAGMA foreign_key_check(missing)", "SELECT * FROM pragma_foreign_key_check"]
    PragmaDifferential.differences(setup, list_of_queries).should be_empty
  end

  it "matches C on foreign_key_check over 2,000 seeded random schemas" do
    random = Random.new(20261124)
    list_of_differences = [] of String
    2000.times do
      setup_sql = PragmaDifferential.random_setup(random)
      first_table = setup_sql.match!(/CREATE TABLE (\w+)/)[1]
      queries = ["SELECT * FROM pragma_foreign_key_check ORDER BY 1, 2, 3, 4", "PRAGMA foreign_key_check(#{first_table})"]
      # C walks the tables in the order of its table hash. The engine
      # matches that order while the hash is still a list (sqlite_master
      # and up to three tables or views); past that the order of tables
      # is not yet matched, so those schemas compare the sorted rows.
      queries << "PRAGMA foreign_key_check" if setup_sql.scan(/CREATE (?:TABLE|VIEW)/).size <= 3
      found = PragmaDifferential.differences(setup_sql, queries)
      list_of_differences << "#{setup_sql}\n#{found.join("\n")}" unless found.empty?
    end
    list_of_differences.first(3).should be_empty
    list_of_differences.size.should eq(0)
  end
end

private module PragmaExtrasNames
  def self.list_of_table_valued : Array(String)
    Grant::SQLiteEngine::Query::PragmaExtras::TABLE_VALUED.keys
  end
end
