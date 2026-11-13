require "../../../spec_helper"

# Audit defect D6: the `regexp` SQL function SQLite calls from C. A NULL
# argument or a malformed pattern must reach the caller as an SQL result,
# never as a Crystal exception unwinding through SQLite.
private def with_regexp_database(&)
  path = File.tempname("grant_regexp_function", ".sqlite3")
  db = DB.open("sqlite3:#{path}?max_pool_size=1")
  begin
    db.exec "CREATE TABLE fruits (id INTEGER PRIMARY KEY, name TEXT)"
    db.exec "INSERT INTO fruits (name) VALUES ('apple'), (NULL), ('banana')"
    yield db
  ensure
    db.close
    File.delete(path) if File.exists?(path)
  end
end

describe "Grant::SQLite3 regexp function" do
  it "skips rows whose value is NULL" do
    with_regexp_database do |db|
      db.query_all("SELECT name FROM fruits WHERE name REGEXP ? ORDER BY id", "an", as: String)
        .should eq ["banana"]
    end
  end

  it "matches every non-NULL row with an empty pattern and returns NULL for a NULL argument" do
    with_regexp_database do |db|
      db.query_all("SELECT name FROM fruits WHERE name REGEXP ? ORDER BY id", "", as: String)
        .should eq ["apple", "banana"]
      db.query_one("SELECT NULL REGEXP 'a'", as: Int64?).should be_nil
      db.query_one("SELECT 'a' REGEXP NULL", as: Int64?).should be_nil
      db.query_one("SELECT 'a' REGEXP 'a'", as: Int64).should eq 1
    end
  end

  it "reports a malformed pattern as a query error and keeps the connection usable" do
    with_regexp_database do |db|
      expect_raises(Grant::SQLite3::Exception, /regexp/) do
        db.query_all("SELECT name FROM fruits WHERE name REGEXP ?", "(", as: String)
      end
      db.scalar("SELECT 1").should eq 1
      db.query_all("SELECT name FROM fruits WHERE name REGEXP ? ORDER BY id", "^a", as: String)
        .should eq ["apple"]
    end
  end

  it "reads text holding a NUL byte whole" do
    with_regexp_database do |db|
      db.query_one("SELECT CAST(? AS TEXT) REGEXP ?", "ab\u0000cd", "cd$", as: Int64).should eq 1
    end
  end
end
