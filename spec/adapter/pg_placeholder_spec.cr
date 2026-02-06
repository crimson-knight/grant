require "../spec_helper"

# Test PG adapter's ensure_clause_template without requiring a PG database.
# We instantiate the PG adapter with a dummy URL and test the method directly.
describe "PG ensure_clause_template" do
  pg_adapter = Grant::Adapter::Pg.new(name: "pg_test", url: "postgres://localhost/test")

  it "converts a single ? to $1" do
    result = pg_adapter.ensure_clause_template("id = ?")
    result.should eq "id = $1"
  end

  it "converts multiple ? to $1, $2, $3" do
    result = pg_adapter.ensure_clause_template("name = ? AND age = ? AND active = ?")
    result.should eq "name = $1 AND age = $2 AND active = $3"
  end

  it "returns clause unchanged when no ? present" do
    result = pg_adapter.ensure_clause_template("SELECT * FROM users")
    result.should eq "SELECT * FROM users"
  end

  it "handles DELETE statement with ? placeholders" do
    result = pg_adapter.ensure_clause_template("DELETE FROM users WHERE id = ?")
    result.should eq "DELETE FROM users WHERE id = $1"
  end

  it "handles UPDATE statement with ? placeholders" do
    result = pg_adapter.ensure_clause_template("UPDATE users SET name = ?, age = ? WHERE id = ?")
    result.should eq "UPDATE users SET name = $1, age = $2 WHERE id = $3"
  end

  it "handles IS NULL clauses mixed with ? placeholders" do
    result = pg_adapter.ensure_clause_template("name IS NULL AND age = ?")
    result.should eq "name IS NULL AND age = $1"
  end
end

# Verify that the base adapter's ensure_clause_template is a no-op
describe "SQLite ensure_clause_template" do
  it "returns clause unchanged (? is native for SQLite)" do
    sqlite_adapter = Grant::Adapter::Sqlite.new(name: "sqlite_test", url: "sqlite3::memory:")
    result = sqlite_adapter.ensure_clause_template("id = ? AND name = ?")
    result.should eq "id = ? AND name = ?"
  end
end
