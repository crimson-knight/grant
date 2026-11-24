require "spec"
require "../../../../src/grant/sqlite_engine"

private alias SQL = Grant::SQLiteEngine::SQL

# The shortcut's tree, field by field, as the parser's tree.
private def same_as_parser(sql : String) : Nil
  shortcut = SQL::SavepointText.parse(sql)
  parsed = SQL::Parser.parse(sql)
  fail "no shortcut for #{sql.inspect}" unless shortcut
  fail "the parser found no statement in #{sql.inspect}" unless parsed
  shortcut.class.should eq(parsed.class)
  shortcut.to_sql.should eq(parsed.to_sql)
  if shortcut.is_a?(SQL::Savepoint) && parsed.is_a?(SQL::Savepoint)
    shortcut.name.should eq(parsed.name)
  end
  if shortcut.is_a?(SQL::Release) && parsed.is_a?(SQL::Release)
    shortcut.name.should eq(parsed.name)
    shortcut.savepoint_keyword.should eq(parsed.savepoint_keyword)
  end
end

describe Grant::SQLiteEngine::SQL::SavepointText do
  it "reads SAVEPOINT and RELEASE of a bare name as the parser does" do
    ["SAVEPOINT sp_1", "savepoint Sp_20", "  SAVEPOINT\tsp_3 ;  ", "SAVEPOINT a;",
     "RELEASE SAVEPOINT sp_1", "RELEASE sp_1", "release savepoint X9", "\nRELEASE\nSAVEPOINT\nsp_4\n;\n"].each do |sql|
      same_as_parser(sql)
    end
  end

  it "leaves every other spelling to the parser" do
    ["SAVEPOINT \"sp 1\"", "SAVEPOINT [sp]", "SAVEPOINT `sp`", "SAVEPOINT 'sp'",
     "SAVEPOINT begin", "SAVEPOINT savepoint", "RELEASE savepoint", "RELEASE SAVEPOINT",
     "SAVEPOINT 1sp", "SAVEPOINT sp; SELECT 1", "SAVEPOINT sp;;", "SAVEPOINT sp -- note",
     "SAVEPOINT /* note */ sp", "SAVEPOINT spé", "SAVEPOINT sp$1", "SAVEPOINT", "ROLLBACK TO sp",
     "SAVEPOINTsp", "SAVEPOINT sp sp", "BEGIN", "COMMIT"].each do |sql|
      SQL::SavepointText.parse(sql).should be_nil
    end
  end
end
