require "../../support/schema_fixture"
require "../../support/test_connection"

class M02aStampedRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_stamped_rows

  column id : Int64, primary: true
  column name : String?
  column created_at : Time?, null: false
  column updated_at : Time?
end

describe "Timestamp DDL" do
  describe "t.timestamps in every dialect" do
    it "is NOT NULL with microsecond precision by default" do
      body = ->(t : Grant::Schema::TableDefinition) { t.timestamps }
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02a_t, id: false) { |t| body.call(t) }.first
      pg.should contain %("created_at" TIMESTAMP(6) NOT NULL)
      pg.should contain %("updated_at" TIMESTAMP(6) NOT NULL)
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_table_statements(:m02a_t, id: false) { |t| body.call(t) }.first
      my.should contain "`created_at` DATETIME(6) NOT NULL"
      lite = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).create_table_statements(:m02a_t, id: false) { |t| body.call(t) }.first
      lite.should contain %("updated_at" DATETIME NOT NULL)
    end

    it "honors precision: and null:" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02a_t, id: false) do |t|
        t.timestamps precision: 3, null: true
      end.first
      sql.should contain %("created_at" TIMESTAMP(3),)
      sql.should contain %("updated_at" TIMESTAMP(3)\n)
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_table_statements(:m02a_t, id: false) { |t| t.timestamps precision: 0 }
        .first.should contain "`created_at` DATETIME(0) NOT NULL"
    end
  end

  describe "add_timestamps and remove_timestamps SQL" do
    it "uses one ALTER on PostgreSQL and MySQL" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).add_timestamps_statements(:users).should eq [
        "ALTER TABLE \"users\" ADD COLUMN \"created_at\" TIMESTAMP(6) NOT NULL, ADD COLUMN \"updated_at\" TIMESTAMP(6) NOT NULL",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).add_timestamps_statements(:users, precision: 3, null: true).should eq [
        "ALTER TABLE `users` ADD COLUMN `created_at` DATETIME(3), ADD COLUMN `updated_at` DATETIME(3)",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).remove_timestamps_statements(:users).should eq [
        "ALTER TABLE \"users\" DROP COLUMN \"created_at\", DROP COLUMN \"updated_at\"",
      ]
    end

    it "uses one ALTER per column on SQLite and refuses a NOT NULL add without default" do
      lite = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      lite.add_timestamps_statements(:users, null: true).should eq [
        "ALTER TABLE \"users\" ADD COLUMN \"created_at\" DATETIME",
        "ALTER TABLE \"users\" ADD COLUMN \"updated_at\" DATETIME",
      ]
      lite.remove_timestamps_statements(:users).size.should eq 2
      expect_raises(Grant::Schema::UnsupportedOperation, /without a default/) { lite.add_timestamps_statements(:users) }
      lite.add_timestamps_statements(:users, default: "1970-01-01 00:00:00").first.should contain "NOT NULL DEFAULT '1970-01-01 00:00:00'"
    end
  end

  describe "model timestamp columns" do
    it "honors null: false in the create SQL" do
      TestConnection.ensure_registered
      sql = M02aStampedRow.migrator.create_sql
      sql.should match(/created_at["`] [A-Z0-9()]+ NOT NULL/)
      sql.should_not match(/updated_at["`] [A-Z0-9()]+ NOT NULL/)
    end
  end

  describe "on #{CURRENT_ADAPTER}" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)

    after_all do
      statements.drop_table(:m02a_stamps, if_exists: true)
      M02aStampedRow.migrator.drop
    end

    it "creates NOT NULL timestamps and rejects a null" do
      statements.drop_table(:m02a_stamps, if_exists: true)
      statements.create_table(:m02a_stamps) do |t|
        t.string :name
        t.timestamps
      end
      columns = SchemaFixture.adapter.schema.columns(:m02a_stamps).index_by(&.name)
      columns["created_at"].null?.should be_false
      columns["updated_at"].null?.should be_false
      expect_raises(Grant::ErrorBase) do
        SchemaFixture.adapter.open { |db| db.exec "INSERT INTO m02a_stamps (name) VALUES ('x')" }
      end
    end

    it "adds and removes timestamps on an existing table" do
      statements.drop_table(:m02a_stamps, if_exists: true)
      statements.create_table(:m02a_stamps) { |t| t.string :name }
      if CURRENT_ADAPTER == "sqlite"
        expect_raises(Grant::Schema::UnsupportedOperation) { statements.add_timestamps(:m02a_stamps) }
        statements.add_timestamps(:m02a_stamps, default: "1970-01-01 00:00:00")
      else
        statements.add_timestamps(:m02a_stamps)
      end
      columns = SchemaFixture.adapter.schema.columns(:m02a_stamps)
      columns.map(&.name).should eq ["id", "name", "created_at", "updated_at"]
      columns.reject(&.name.in?("id", "name")).all? { |column| !column.null? }.should be_true

      statements.remove_timestamps(:m02a_stamps)
      SchemaFixture.adapter.schema.columns(:m02a_stamps).map(&.name).should eq ["id", "name"]

      statements.add_timestamps(:m02a_stamps, null: true, precision: 3)
      SchemaFixture.adapter.schema.columns(:m02a_stamps).find! { |column| column.name == "created_at" }.null?.should be_true
    end

    it "enforces NOT NULL on a model column declared null: false" do
      TestConnection.ensure_registered
      M02aStampedRow.migrator.drop_and_create
      SchemaFixture.adapter.schema.columns(:m02a_stamped_rows).find! { |column| column.name == "created_at" }.null?.should be_false
      SchemaFixture.adapter.schema.columns(:m02a_stamped_rows).find! { |column| column.name == "updated_at" }.null?.should be_true
    end
  end
end
