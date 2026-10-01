require "../../support/schema_fixture"

# change_column_default on every adapter. SQLite has no ALTER COLUMN, so it
# rebuilds the table; the rows, the other columns' constraints and the
# indexes survive the rebuild.
describe "change_column_default via table rebuild" do
  statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
  adapter = SchemaFixture.adapter

  insert_empty = ->(table : String) do
    sql = CURRENT_ADAPTER == "mysql" ? "INSERT INTO #{table} () VALUES ()" : "INSERT INTO #{table} DEFAULT VALUES"
    adapter.open { |db| db.exec sql }
  end

  column_default = ->(table : String, name : String) do
    adapter.reset_schema_caches!
    adapter.schema.columns(table).find! { |column| column.name == name }.default
  end

  before_each do
    statements.drop_table(:w6b_defaults, if_exists: true)
    statements.create_table(:w6b_defaults) do |t|
      t.string :role, null: false, default: "it's member"
      t.integer :qty, default: 1
      t.string :label
      t.index :label, unique: true
    end
    adapter.open { |db| db.exec "INSERT INTO w6b_defaults (role, qty, label) VALUES ('kept', 7, 'one')" }
  end

  after_all { statements.drop_table(:w6b_defaults, if_exists: true) }

  it "sets a new literal default and keeps the rows" do
    statements.change_column_default(:w6b_defaults, :role, from: "it's member", to: "admin")
    insert_empty.call("w6b_defaults")
    adapter.open { |db| db.query_one("SELECT role FROM w6b_defaults WHERE qty = 1", as: String) }.should eq "admin"
    adapter.open { |db| db.query_one("SELECT role FROM w6b_defaults WHERE label = 'one'", as: String) }.should eq "kept"
  end

  it "replaces a default that holds an escaped quote" do
    statements.change_column_default(:w6b_defaults, :role, to: "o'neil")
    insert_empty.call("w6b_defaults")
    adapter.open { |db| db.query_one("SELECT role FROM w6b_defaults WHERE qty = 1", as: String) }.should eq "o'neil"
  end

  it "drops the default and keeps NOT NULL" do
    statements.change_column_default(:w6b_defaults, :role, to: nil)
    column_default.call("w6b_defaults", "role").should be_nil
    adapter.schema.columns(:w6b_defaults).find! { |column| column.name == "role" }.null?.should be_false
    expect_raises(Exception) { insert_empty.call("w6b_defaults") }
  end

  it "sets an expression default and leaves the other defaults alone" do
    statements.change_column_default(:w6b_defaults, :qty, default_sql: "2 * 5")
    insert_empty.call("w6b_defaults")
    adapter.open { |db| db.query_one("SELECT qty FROM w6b_defaults WHERE qty <> 7", as: Int).to_i64 }.should eq 10
    adapter.open { |db| db.query_one("SELECT role FROM w6b_defaults WHERE qty <> 7", as: String) }.should eq "it's member"
  end

  it "keeps the unique index" do
    statements.change_column_default(:w6b_defaults, :label, to: "x")
    adapter.reset_schema_caches!
    adapter.schema.indexes(:w6b_defaults).any? { |index| index.columns == ["label"] && index.unique? }.should be_true
  end

  it "renders the rebuild SQL on the recording mock" do
    # The recording mock gives the SQLite statement list without a database.
    if CURRENT_ADAPTER == "sqlite"
      recorder = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      definition = %(CREATE TABLE "users" ("id" INTEGER PRIMARY KEY, "role" VARCHAR(255) DEFAULT 'a b' NOT NULL))
      recorder.sqlite_tables["users"] = {definition, [] of String}
      sql = recorder.change_column_default_statements(:users, :role, to: "c").join("\n")
      sql.should contain %("role" VARCHAR(255)  NOT NULL DEFAULT 'c')
      sql.should_not contain "'a b'"
    end
  end

  it "needs a target" do
    expect_raises(Grant::Schema::InvalidDefinition) { statements.change_column_default(:w6b_defaults, :role) }
  end
end
