require "spec"
require "file_utils"
require "../../../../src/grant/drivers/sqlite3/sqlite3/type"
require "../../../../src/grant/drivers/sqlite3/sqlite3/flags"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine"
require "../../../../src/grant/drivers/sqlite3/sqlite3/engine/grant_engine"
require "../../../../src/grant/drivers/sqlite3/libsqlite3"

# Runs ANALYZE and PRAGMA optimize through Grant's engine and libsqlite3 on
# the same schema and rows, and compares result codes, column names, the
# rows of sqlite_stat1 (in rowid order) and its sqlite_master row.
private module AnalyzeDifferential
  alias Engine = Grant::SQLite3::Engine

  STATISTICS = "SELECT rowid, tbl, idx, stat FROM sqlite_stat1"
  SORTED     = "SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY 1, 2"
  MASTER     = "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name = 'sqlite_stat1'"

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
          raise "setup failed: #{database.error_message}\n#{setup}" unless setup_code == Engine::OK_CODE
        end
        list_of_queries.each { |sql| results << "#{pass} #{sql} => #{outcome(database, sql)}" }
      ensure
        database.close
      end
    end
    results
  end

  # The differences between the engines, and what /usr/bin/sqlite3 says of
  # the file Grant's engine wrote when *checks_file* is set.
  def self.differences(setup : String, list_of_queries : Array(String), checks_file : Bool = false) : Array(String)
    directory = File.tempname("analyze")
    Dir.mkdir_p(directory)
    begin
      expected = outcomes(Engine::LibSQLite3Engine.new, File.join(directory, "c.db"), setup, list_of_queries)
      actual = outcomes(Engine::GrantEngine.new, File.join(directory, "grant.db"), setup, list_of_queries)
      list = expected.zip(actual).compact_map { |c, grant| c == grant ? nil : "C:     #{c}\n      Grant: #{grant}" }
      if checks_file
        check = `/usr/bin/sqlite3 #{File.join(directory, "grant.db")} "PRAGMA integrity_check"`.strip
        list << "integrity_check: #{check}" unless check == "ok"
      end
      list
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  VALUE_KINDS = %w[small wide text mixed_case null_heavy constant real]

  def self.random_value(random : Random, kind : String, row : Int32) : String
    case kind
    when "small"      then random.rand(1..4).to_s
    when "wide"       then random.rand(1..100_000).to_s
    when "text"       then "'w#{random.rand(1..12)}'"
    when "mixed_case" then "'#{%w[ada Ada ADA bob Bob cy][random.rand(6)]}'"
    when "null_heavy" then random.rand(3) == 0 ? random.rand(1..3).to_s : "NULL"
    when "constant"   then "7"
    else                   "#{random.rand(1..6)}.5"
    end
  end

  # A random schema: tables with and without rowid, UNIQUE and NOT NULL
  # columns, plain, descending, NOCASE, partial and expression indexes,
  # and rows whose columns repeat or vary. Returns the setup, the table
  # names and the index names.
  def self.random_schema(random : Random) : {String, Array(String), Array(String)}
    list_of_tables = [] of String
    list_of_indexes = [] of String
    used = Set(String).new
    setup = String.build do |sql|
      random.rand(1..7).times do |table_index|
        name = "#{%w[author post Tag comment_ x LONGER_table_name q][table_index]}#{random.rand(100)}"
        next unless used.add?(name.downcase)
        list_of_tables << name
        without_rowid = random.rand(5) == 0
        not_null = Array.new(4) { random.rand(3) == 0 }
        not_null[0] = true if without_rowid
        sql << "CREATE TABLE #{name}(a INTEGER#{" NOT NULL" if not_null[0]}, b#{" NOT NULL" if not_null[1]}, "
        sql << "c TEXT#{" COLLATE NOCASE" if random.rand(4) == 0}#{" NOT NULL" if not_null[2]}, d#{" NOT NULL" if not_null[3]}"
        sql << ", k INTEGER PRIMARY KEY" if !without_rowid && random.rand(3) == 0
        sql << ", k2 INTEGER DEFAULT 0" if without_rowid
        sql << ", PRIMARY KEY(#{random.rand(2) == 0 ? "a" : "a, k2"})" if without_rowid
        sql << ", UNIQUE(#{%w[a b d].sample(random)}, c)" if random.rand(6) == 0
        sql << ")#{" WITHOUT ROWID" if without_rowid};\n"
        random.rand(0..4).times do |index_number|
          index_name = "index_#{name}_#{index_number}"
          list_of_indexes << index_name
          columns = case random.rand(8)
                    when 0 then "a"
                    when 1 then "b, a"
                    when 2 then "c COLLATE NOCASE, d"
                    when 3 then "d DESC, b"
                    when 4 then "lower(c)"
                    when 5 then "a + 1, c"
                    when 6 then "b, c, d, a"
                    else        "d"
                    end
          unique = random.rand(8) == 0 ? "UNIQUE " : ""
          where = random.rand(4) == 0 ? " WHERE #{["a > 2", "b IS NOT NULL", "c = 'ada'"].sample(random)}" : ""
          sql << "CREATE #{unique}INDEX #{index_name} ON #{name}(#{columns})#{where};\n"
        end
        list_of_kinds = Array.new(4) { VALUE_KINDS.sample(random) }
        row_count = random.rand(4) == 0 ? 0 : random.rand(1..([3, 12, 60, 200].sample(random)))
        row_count.times do |row|
          values = list_of_kinds.map_with_index do |kind, column|
            value = random_value(random, kind, row)
            value == "NULL" && not_null[column] ? "0" : value
          end
          values[0] = (row + 1).to_s if without_rowid
          sql << "INSERT OR IGNORE INTO #{name}(a, b, c, d) VALUES (#{values.join(", ")});\n"
        end
      end
    end
    {setup, list_of_tables, list_of_indexes}
  end

  # ANALYZE in its forms with the statistics read after each, then rows
  # changed and one object analyzed again.
  def self.random_queries(random : Random, list_of_tables : Array(String), list_of_indexes : Array(String),
                          statistics : String) : Array(String)
    table = list_of_tables.sample(random)
    list = [] of String
    list << "PRAGMA analysis_limit=#{[1, 2, 5, 50].sample(random)}" if random.rand(5) == 0
    list << "PRAGMA optimize(#{["0x10003", "3", "0xfffe", "0x10002", "1"].sample(random)})" if random.rand(3) == 0
    list << statistics if list.size > 0 && random.rand(2) == 0
    list << ["ANALYZE", "ANALYZE main", "ANALYZE #{table}", "ANALYZE main.#{table}"].sample(random)
    list << statistics << MASTER
    list << "DELETE FROM #{table} WHERE a % 3 = 0" if random.rand(3) == 0
    list << "INSERT OR IGNORE INTO #{table}(a, b, c, d) SELECT a + 1000, b, c, d FROM #{table}" if random.rand(3) == 0
    second = list_of_tables.sample(random)
    list << case random.rand(6)
    when 0 then "ANALYZE"
    when 1 then "ANALYZE #{second}"
    when 2 then list_of_indexes.empty? ? "ANALYZE #{second}" : "ANALYZE #{list_of_indexes.sample(random)}"
    when 3 then "PRAGMA optimize(0x10002)"
    when 4 then "PRAGMA optimize(0x10003)"
    else        "PRAGMA optimize"
    end
    list << statistics << MASTER << "SELECT changes(), total_changes() > 0"
    list
  end
end

describe "Grant::SQLiteEngine ANALYZE and sqlite_stat1" do
  setup = <<-SQL
    CREATE TABLE authors(id INTEGER PRIMARY KEY, first_name TEXT NOT NULL, email TEXT UNIQUE, city TEXT);
    CREATE INDEX index_authors_on_city ON authors(city);
    CREATE INDEX index_authors_on_lower_email ON authors(lower(email));
    CREATE TABLE posts(id INTEGER PRIMARY KEY, author_id INTEGER, score INTEGER, title TEXT COLLATE NOCASE);
    CREATE INDEX index_posts_on_author_id ON posts(author_id);
    CREATE INDEX index_posts_on_score_and_title ON posts(score DESC, title);
    CREATE INDEX index_posts_on_high_score ON posts(title) WHERE score > 5;
    CREATE TABLE tags(label TEXT, weight INTEGER);
    CREATE TABLE empty_table(first_value, second_value);
    CREATE INDEX index_empty_table ON empty_table(first_value);
    CREATE INDEX index_empty_partial ON empty_table(second_value) WHERE first_value > 1;
    CREATE TABLE only_partial(first_value, second_value);
    CREATE INDEX index_only_partial ON only_partial(second_value) WHERE first_value > 1;
    CREATE TABLE memberships(author_id INTEGER, post_id INTEGER, role TEXT, PRIMARY KEY(author_id, post_id)) WITHOUT ROWID;
    CREATE INDEX index_memberships_on_role ON memberships(role);
    CREATE VIEW view_of_posts AS SELECT id FROM posts;
    INSERT INTO authors VALUES (1, 'Ada', 'ada@example.com', 'Keene'), (2, 'Brian', 'brian@example.com', 'Keene'),
      (3, 'Cy', NULL, NULL), (4, 'Di', NULL, 'Dover');
    INSERT INTO posts VALUES (1, 1, 9, 'Alpha'), (2, 1, 9, 'alpha'), (3, 2, 3, 'Beta'), (4, 2, 7, 'Gamma'), (5, NULL, NULL, NULL);
    INSERT INTO tags VALUES ('red', 1), ('blue', 2), ('red', 3);
    INSERT INTO only_partial VALUES (1, 'x'), (2, 'y'), (3, 'y');
    INSERT INTO memberships VALUES (1, 1, 'owner'), (1, 2, 'owner'), (2, 3, 'reader');
    SQL

  statistics = AnalyzeDifferential::STATISTICS
  master = AnalyzeDifferential::MASTER

  it "has no STAT4 in the reference library" do
    code, database = Grant::SQLite3::Engine::LibSQLite3Engine.new.open(":memory:")
    code.should eq(Grant::SQLite3::Engine::OK_CODE)
    AnalyzeDifferential.outcome(database, "SELECT count(*) FROM pragma_compile_options WHERE compile_options LIKE '%STAT4%'")
      .should contain(%([["i:0"]]))
    database.close
  end

  it "analyzes the whole database as C does" do
    AnalyzeDifferential.differences(setup, ["ANALYZE", statistics, master, "ANALYZE main", statistics,
                                            "SELECT changes(), total_changes(), last_insert_rowid()"], checks_file: true).should be_empty
  end

  it "analyzes one table, one index and schema-qualified names as C does" do
    AnalyzeDifferential.differences(setup, ["ANALYZE posts", statistics, master, "ANALYZE index_authors_on_city", statistics,
                                            "ANALYZE main.memberships", statistics, "ANALYZE main.index_posts_on_high_score",
                                            statistics, "ANALYZE empty_table", "ANALYZE only_partial", "ANALYZE tags", statistics,
                                            "ANALYZE view_of_posts", "ANALYZE sqlite_master", "ANALYZE missing_table",
                                            "ANALYZE main.missing_table", "ANALYZE missing_schema.posts", statistics], checks_file: true).should be_empty
  end

  it "replaces only the rows of the analyzed objects" do
    AnalyzeDifferential.differences(setup, ["ANALYZE", "DELETE FROM posts WHERE id > 2", "ANALYZE posts", statistics,
                                            "INSERT INTO tags VALUES ('green', 4)", "ANALYZE index_posts_on_author_id", statistics,
                                            "DELETE FROM tags", "ANALYZE tags", statistics, "DELETE FROM authors", "ANALYZE", statistics],
      checks_file: true).should be_empty
  end

  it "reads, writes and drops sqlite_stat1 as C does" do
    AnalyzeDifferential.differences(setup, ["SELECT * FROM sqlite_stat1", "CREATE TABLE sqlite_stat1(tbl,idx,stat)", "ANALYZE",
                                            "UPDATE sqlite_stat1 SET stat = '1000 10' WHERE idx = 'index_posts_on_author_id'",
                                            "INSERT INTO sqlite_stat1 VALUES ('posts', NULL, '77')", "DELETE FROM sqlite_stat1 WHERE tbl = 'tags'",
                                            statistics, "ANALYZE sqlite_master", "DROP TABLE sqlite_stat1", master, statistics, "ANALYZE authors",
                                            statistics, master], checks_file: true).should be_empty
  end

  it "analyzes inside a transaction and undoes it on rollback" do
    AnalyzeDifferential.differences(setup, ["BEGIN", "ANALYZE", statistics, "ROLLBACK", statistics, master, "BEGIN", "ANALYZE posts",
                                            "COMMIT", statistics], checks_file: true).should be_empty
  end

  it "honors analysis_limit" do
    wide = String.build do |sql|
      sql << "CREATE TABLE wide(first_value, second_value, third_value);\n"
      sql << "CREATE INDEX index_wide_on_first ON wide(first_value, second_value);\n"
      sql << "CREATE INDEX index_wide_on_third ON wide(third_value);\n"
      sql << "CREATE UNIQUE INDEX index_wide_unique ON wide(second_value);\n"
      300.times { |row| sql << "INSERT INTO wide VALUES (#{row // 100}, #{row}, 5);\n" }
    end
    AnalyzeDifferential.differences(wide, ["PRAGMA analysis_limit", "PRAGMA analysis_limit=10", "ANALYZE", statistics,
                                           "PRAGMA analysis_limit=120", "ANALYZE", statistics, "PRAGMA analysis_limit=-5",
                                           "PRAGMA analysis_limit=0x20", "SELECT * FROM pragma_analysis_limit", "ANALYZE", statistics,
                                           "PRAGMA analysis_limit=0", "ANALYZE", statistics], checks_file: true).should be_empty
  end

  it "runs PRAGMA optimize where C does and lists the statements for mask 0x01" do
    AnalyzeDifferential.differences(setup, ["PRAGMA optimize(1)", "PRAGMA optimize(3)", "PRAGMA optimize(0x10003)", "PRAGMA optimize(0x10001)",
                                            "PRAGMA main.optimize(3)", "PRAGMA optimize", statistics, "PRAGMA optimize(0x10003)",
                                            "INSERT INTO tags SELECT label, weight FROM posts, authors, tags", "PRAGMA optimize(0x10003)",
                                            "PRAGMA optimize(0x10002)", statistics, "SELECT * FROM pragma_optimize(3)"], checks_file: true).should be_empty
  end

  it "matches C on random schemas, rows and ANALYZE forms" do
    count = (ENV["ANALYZE_DIFFERENTIAL_COUNT"]? || "2000").to_i
    seed = (ENV["ANALYZE_DIFFERENTIAL_SEED"]? || "20261124").to_u64
    random = Random.new(seed)
    failures = [] of String
    count.times do |iteration|
      schema, list_of_tables, list_of_indexes = AnalyzeDifferential.random_schema(random)
      statistics_query = statistics
      list_of_queries = AnalyzeDifferential.random_queries(random, list_of_tables, list_of_indexes, statistics_query)
      # ANALYZE_DIFFERENTIAL_ONLY reruns one iteration and prints its statements.
      if only = ENV["ANALYZE_DIFFERENTIAL_ONLY"]?
        next unless iteration == only.to_i
        puts schema.lines.reject(&.starts_with?("INSERT")).join, list_of_queries.join(";\n")
      end
      list = AnalyzeDifferential.differences(schema, list_of_queries, checks_file: iteration % 20 == 0)
      failures << "iteration #{iteration}:\n#{schema}#{list.first(2).join("\n")}" unless list.empty?
      break if failures.size >= 3
    end
    puts "analyze random differential: seed #{seed}, #{count} schemas, #{failures.size} differences"
    failures.should be_empty
  end
end
