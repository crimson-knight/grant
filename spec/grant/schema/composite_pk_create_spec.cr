require "../../support/schema_fixture"
require "../../support/test_connection"
require "../../../src/grant/composite_primary_key"

class M02aLineItem < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_line_items

  column order_id : Int64, primary: true, auto: false
  column product_id : Int64, primary: true, auto: false
  column quantity : Int32

  composite_primary_key order_id, product_id
end

describe "Composite primary keys in table creation" do
  describe "DSL in every dialect" do
    it "emits PRIMARY KEY (a, b) for an explicit key list" do
      Grant::Schema::Dialect.each do |dialect|
        sql = Grant::Schema::RecordingStatements.new(dialect).create_table_statements(:m02a_pairs, id: false, primary_key: [:a_id, :b_id]) do |t|
          t.bigint :a_id
          t.bigint :b_id
          t.string :note
        end.first
        sql.should contain "PRIMARY KEY (#{dialect.quote("a_id")}, #{dialect.quote("b_id")})"
        sql.scan("PRIMARY KEY").size.should eq 1
        sql.should contain "#{dialect.quote("a_id")} #{dialect.pg? ? "BIGINT" : "BIGINT"} NOT NULL"
      end
    end

    it "collects columns flagged primary_key: true" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02a_flagged, id: false) do |t|
        t.bigint :a_id, primary_key: true
        t.bigint :b_id, primary_key: true
      end.first
      sql.should eq "CREATE TABLE \"m02a_flagged\" (\n  \"a_id\" BIGINT NOT NULL,\n  \"b_id\" BIGINT NOT NULL,\n  PRIMARY KEY (\"a_id\", \"b_id\")\n)"
    end

    it "makes a single flagged column the key and skips the auto id" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).create_table_statements(:m02a_one) do |t|
        t.string :code, primary_key: true, null: false
      end.first
      sql.should eq "CREATE TABLE \"m02a_one\" (\n  \"code\" VARCHAR(255) NOT NULL PRIMARY KEY\n)"
    end

    it "renames the auto key with primary_key: and rejects unknown or doubled keys" do
      rec = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      rec.create_table_statements(:m02a_named, primary_key: :ident) { }.first.should contain "`ident` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
      expect_raises(Grant::Schema::InvalidDefinition, /not defined/) do
        rec.create_table_statements(:m02a_bad, id: false, primary_key: [:a, :b]) { |t| t.integer :a }
      end
      expect_raises(Grant::Schema::InvalidDefinition, /not both/) do
        rec.create_table_statements(:m02a_bad, id: false, primary_key: [:a, :b]) { |t| t.integer :a, primary_key: true; t.integer :b }
      end
    end
  end

  describe "on #{CURRENT_ADAPTER}" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)

    after_all do
      statements.drop_table(:m02a_pairs, if_exists: true)
      M02aLineItem.migrator.drop
    end

    it "creates a real composite key table and enforces it" do
      statements.drop_table(:m02a_pairs, if_exists: true)
      statements.create_table(:m02a_pairs, id: false, primary_key: [:a_id, :b_id]) do |t|
        t.bigint :a_id
        t.bigint :b_id
        t.string :note
      end
      columns = SchemaFixture.adapter.schema.columns(:m02a_pairs)
      columns.select(&.primary_key?).map(&.name).sort!.should eq ["a_id", "b_id"]
      SchemaFixture.adapter.open do |db|
        db.exec "INSERT INTO m02a_pairs (a_id, b_id) VALUES (1, 1)"
        db.exec "INSERT INTO m02a_pairs (a_id, b_id) VALUES (1, 2)"
      end
      expect_raises(Grant::ErrorBase) do
        SchemaFixture.adapter.open { |db| db.exec "INSERT INTO m02a_pairs (a_id, b_id) VALUES (1, 2)" }
      end
    end

    it "derives PRIMARY KEY (a, b) from a model with several primary columns" do
      TestConnection.ensure_registered
      sql = M02aLineItem.migrator.create_sql
      sql.should contain "PRIMARY KEY (#{CURRENT_ADAPTER == "mysql" ? "`order_id`, `product_id`" : "\"order_id\", \"product_id\""})"
      sql.scan("PRIMARY KEY").size.should eq 1
      sql.should_not contain "SERIAL"
      M02aLineItem.migrator.drop_and_create
      SchemaFixture.adapter.schema.columns(:m02a_line_items).select(&.primary_key?).map(&.name).sort!.should eq ["order_id", "product_id"]
      # Composite key models do not persist through save yet, so insert directly.
      SchemaFixture.adapter.open do |db|
        db.exec "INSERT INTO m02a_line_items (order_id, product_id, quantity) VALUES (1, 1, 2)"
        db.exec "INSERT INTO m02a_line_items (order_id, product_id, quantity) VALUES (1, 2, 3)"
      end
      M02aLineItem.count.should eq 2
      expect_raises(Grant::ErrorBase) do
        SchemaFixture.adapter.open { |db| db.exec "INSERT INTO m02a_line_items (order_id, product_id, quantity) VALUES (1, 2, 9)" }
      end
    end
  end
end
