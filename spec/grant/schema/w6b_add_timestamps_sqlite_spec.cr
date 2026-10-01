require "../../support/schema_fixture"
require "../../support/test_connection"

# add_timestamps with the default NOT NULL columns on every adapter. SQLite
# cannot ADD COLUMN ... NOT NULL without a default, so it rebuilds the table:
# that succeeds while the table is empty and fails on a populated one (as
# PostgreSQL does), where null: true or a default is the way to add them.
class W6bTimestamped < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_timestamped

  column id : Int64, primary: true
  column name : String?
  timestamps precision: 3, null: false
end

describe "add_timestamps without a default" do
  statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
  adapter = SchemaFixture.adapter

  before_each do
    statements.drop_table(:w6b_stamped, if_exists: true)
    statements.create_table(:w6b_stamped) { |t| t.string :name }
  end

  after_all do
    statements.drop_table(:w6b_stamped, if_exists: true)
    W6bTimestamped.migrator.drop
  end

  it "adds NOT NULL timestamps to an empty table" do
    statements.add_timestamps(:w6b_stamped)
    adapter.reset_schema_caches!
    columns = adapter.schema.columns(:w6b_stamped)
    columns.map(&.name).should eq ["id", "name", "created_at", "updated_at"]
    columns.reject(&.name.in?("id", "name")).all? { |column| !column.null? }.should be_true
    expect_raises(Exception) { adapter.open { |db| db.exec "INSERT INTO w6b_stamped (name) VALUES ('x')" } }
    adapter.open { |db| db.exec "INSERT INTO w6b_stamped (name, created_at, updated_at) VALUES ('x', '2024-01-02 03:04:05', '2024-01-02 03:04:05')" }
  end

  it "keeps the primary key and an index through the rebuild" do
    statements.add_index(:w6b_stamped, :name)
    statements.add_timestamps(:w6b_stamped)
    adapter.reset_schema_caches!
    adapter.schema.primary_key(:w6b_stamped).should eq ["id"]
    adapter.schema.indexes(:w6b_stamped).any? { |index| index.columns == ["name"] }.should be_true
  end

  it "fails on a populated table, and succeeds there with null: true" do
    adapter.open { |db| db.exec "INSERT INTO w6b_stamped (name) VALUES ('old')" }
    expect_raises(Exception) { statements.add_timestamps(:w6b_stamped) }
    adapter.reset_schema_caches!
    adapter.schema.columns(:w6b_stamped).map(&.name).should eq ["id", "name"]
    adapter.open { |db| db.scalar("SELECT COUNT(*) FROM w6b_stamped").as(Int).to_i64 }.should eq 1
    statements.add_timestamps(:w6b_stamped, null: true)
    adapter.reset_schema_caches!
    adapter.schema.columns(:w6b_stamped).find! { |column| column.name == "created_at" }.null?.should be_true
  end

  it "removes them again" do
    statements.add_timestamps(:w6b_stamped)
    statements.remove_timestamps(:w6b_stamped)
    adapter.reset_schema_caches!
    adapter.schema.columns(:w6b_stamped).map(&.name).should eq ["id", "name"]
  end

  it "emits one rebuild for both columns on SQLite and one ALTER elsewhere" do
    dialect = Grant::Schema::Dialect.for(adapter)
    recorder = Grant::Schema::RecordingStatements.new(dialect)
    definition = %(CREATE TABLE "users" ("id" INTEGER PRIMARY KEY, "name" VARCHAR(255)))
    recorder.sqlite_tables["users"] = {definition, [] of String}
    sql = recorder.add_timestamps_statements(:users)
    if dialect.sqlite?
      sql.count(&.starts_with?("CREATE TABLE")).should eq 1
      sql.find!(&.starts_with?("CREATE TABLE")).should contain %("created_at" DATETIME NOT NULL)
    else
      sql.size.should eq 1
    end
  end

  it "gives the model timestamps macro precision and null: in the DDL" do
    TestConnection.ensure_registered
    W6bTimestamped.migrator.drop_and_create
    adapter.reset_schema_caches!
    columns = adapter.schema.columns(:w6b_timestamped).index_by(&.name)
    columns["created_at"].null?.should be_false
    columns["updated_at"].null?.should be_false
    case CURRENT_ADAPTER
    when "mysql" then columns["created_at"].sql_type.downcase.should contain "(3)"
    when "pg"
      adapter.open { |db| db.scalar("SELECT datetime_precision FROM information_schema.columns WHERE table_name = 'w6b_timestamped' AND column_name = 'created_at'").as(Int).to_i64 }.should eq 3
    end
    W6bTimestamped.create(name: "x").created_at.should_not be_nil
    W6bTimestamped.first!.updated_at.should_not be_nil
  end
end
