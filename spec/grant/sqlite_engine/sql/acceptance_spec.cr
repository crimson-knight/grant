require "spec"
require "../../../support/sqlite_engine/sql_oracle"

private alias SQL = Grant::SQLiteEngine::SQL

private CORPUS = Path[__DIR__, "..", "corpus", "grant_sql_corpus.txt"]

# The engine's parser accepts and rejects what the linked C SQLite does.
describe "Grant::SQLiteEngine::SQL acceptance against C SQLite" do
  it "agrees with C on every corpus statement and on each statement printed back" do
    disagreements = [] of String
    File.read_lines(CORPUS).each_with_index(1) do |sql, line|
      c_outcome = SQLiteSQLOracle.verdict(sql)
      engine_outcome = SQLiteSQLOracle.engine_verdict(sql)
      next if c_outcome.verdict.undetermined?
      if c_outcome.verdict != engine_outcome.verdict
        disagreements << "line #{line}: C #{c_outcome.verdict}, engine #{engine_outcome.verdict} #{engine_outcome.message}"
        next
      end
      next unless engine_outcome.verdict.accepted?
      statement = SQL::Parser.parse(sql)
      next unless statement
      printed = statement.to_sql
      again = SQLiteSQLOracle.verdict(printed)
      unless again.verdict.accepted?
        disagreements << "line #{line}: C #{again.verdict} on printed text #{printed} (#{again.message})"
      end
    end
    disagreements.should be_empty
  end

  # Complete statements only: the oracle ends the text with a semicolon, so
  # C reports incomplete input as an error near that semicolon.
  it "rejects with C's message where both parsers reject" do
    [
      "SELECT * FROM t WHERE ORDER",
      "SELECT 1 + * 2",
      "CREATE TABLE t(a, a)",
      "CREATE TABLE t(a PRIMARY KEY, b PRIMARY KEY)",
      "CREATE TABLE t(a TEXT PRIMARY KEY AUTOINCREMENT)",
      "CREATE TABLE sqlite_t(a)",
      "SELECT 1 ORDER BY 1 UNION SELECT 2",
      "SELECT ?0",
      "WITH a AS (SELECT 1), a AS (SELECT 2) SELECT 1",
      "CREATE TABLE t(a, UNIQUE(a) ON CONFLICT FAIL, UNIQUE(a) ON CONFLICT IGNORE)",
    ].each do |sql|
      c_outcome = SQLiteSQLOracle.verdict(sql)
      engine_outcome = SQLiteSQLOracle.engine_verdict(sql)
      c_outcome.verdict.rejected?.should be_true
      engine_outcome.message.should eq(c_outcome.message)
    end
  end
end
