require "../../../spec_helper"

# Audit defect D5: Grant's SQLite adapter wraps the driver's `perform_exec` to
# reset the statement after every exec. The wrapper must keep the driver's
# release of the previous exec's bound values, or a cached insert statement pins
# every string and blob it ever bound until the connection closes.
private def with_exec_bind_database(&)
  path = File.tempname("grant_exec_bind_release", ".sqlite3")
  db = DB.open("sqlite3:#{path}")
  begin
    db.exec "CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT NOT NULL, data BLOB)"
    yield db
  ensure
    db.close
    File.delete(path) if File.exists?(path)
  end
end

private def bound_reference_count(statement : DB::Statement) : Int32
  sqlite_statement = statement.as(Grant::SQLite3::Statement)
  if references = sqlite_statement.@arg_refs
    references.size
  else
    0
  end
end

describe "Grant::SQLite3::Statement exec through the SQLite adapter" do
  it "keeps no more bound values than the last exec bound, across 200 execs" do
    with_exec_bind_database do |db|
      db.using_connection do |connection|
        statement = connection.prepared("INSERT INTO posts (body) VALUES (?)")
        200.times { |index| statement.exec("x" * 10_000 + index.to_s) }

        bound_reference_count(statement).should be <= 1
        connection.scalar("SELECT count(*) FROM posts").should eq 200
      end
    end
  end

  it "holds exactly the last exec's text and blob references, and the row reads back intact" do
    with_exec_bind_database do |db|
      db.using_connection do |connection|
        statement = connection.prepared("INSERT INTO posts (title, body, data) VALUES (?, ?, ?)")
        statement.exec("first title", "first body", Bytes[1, 2, 3])
        statement.exec("second title", "second body", Bytes[4, 5, 6])

        bound_reference_count(statement).should eq 3
        connection.query_one("SELECT title, body, data FROM posts WHERE id = 2", as: {String, String, Bytes})
          .should eq({"second title", "second body", Bytes[4, 5, 6]})
      end
    end
  end

  it "releases a failed exec's bound values on the next exec and leaves the connection able to commit" do
    with_exec_bind_database do |db|
      db.using_connection do |connection|
        statement = connection.prepared("INSERT INTO posts (title, body) VALUES (?, ?)")
        connection.exec "BEGIN"
        expect_raises(Grant::SQLite3::Exception, /NOT NULL/) do
          statement.exec("failed title", nil)
        end
        statement.exec("kept title", "kept body")
        connection.exec "COMMIT"

        bound_reference_count(statement).should eq 2
        connection.query_all("SELECT title FROM posts", as: String).should eq ["kept title"]
      end
    end
  end
end
