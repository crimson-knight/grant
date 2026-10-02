require "../../support/schema_fixture"

describe Grant::Schema::SchemaStatements do
  describe "#create_table_statements SQL per dialect" do
    it "creates a default bigint primary key table" do
      sql = ->(dialect : Grant::Schema::Dialect) do
        Grant::Schema::RecordingStatements.new(dialect).create_table_statements(:m02a_users) do |t|
          t.string :name, null: false, limit: 100
          t.text :bio
        end
      end
      sql.call(Grant::Schema::Dialect::Pg).should eq [
        "CREATE TABLE \"m02a_users\" (\n  \"id\" BIGSERIAL PRIMARY KEY,\n  \"name\" VARCHAR(100) NOT NULL,\n  \"bio\" TEXT\n)",
      ]
      sql.call(Grant::Schema::Dialect::Mysql).should eq [
        "CREATE TABLE `m02a_users` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,\n  `name` VARCHAR(100) NOT NULL,\n  `bio` TEXT\n)",
      ]
      sql.call(Grant::Schema::Dialect::Sqlite).should eq [
        "CREATE TABLE \"m02a_users\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT,\n  \"name\" VARCHAR(100) NOT NULL,\n  \"bio\" TEXT\n)",
      ]
    end

    it "honors if_not_exists and temporary on every dialect" do
      Grant::Schema::Dialect.each do |dialect|
        rec = Grant::Schema::RecordingStatements.new(dialect)
        sql = rec.create_table_statements(:m02a_tmp, id: false, if_not_exists: true, temporary: true) { |t| t.integer :n }.first
        sql.should start_with "CREATE TEMPORARY TABLE IF NOT EXISTS #{dialect.quote("m02a_tmp")} ("
        sql.should_not contain "PRIMARY KEY"
      end
    end

    it "drops first on force, cascading on PostgreSQL only" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.create_table_statements(:m02a_f, force: :cascade) { |t| t.integer :n }.first.should eq "DROP TABLE IF EXISTS \"m02a_f\" CASCADE"
      lite = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      lite.create_table_statements(:m02a_f, force: :cascade) { |t| t.integer :n }.first.should eq "DROP TABLE IF EXISTS \"m02a_f\""
      lite.create_table_statements(:m02a_f, &.integer(:n)).size.should eq 1
    end

    it "supports the id types" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.create_table_statements(:a, id: :uuid) { }.first.should contain "\"id\" UUID PRIMARY KEY DEFAULT gen_random_uuid()"
      pg.create_table_statements(:a, id: :integer, primary_key: :aid) { }.first.should contain "\"aid\" SERIAL PRIMARY KEY"
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      my.create_table_statements(:a, id: :string) { }.first.should contain "`id` VARCHAR(255) PRIMARY KEY"
      expect_raises(Grant::Schema::InvalidDefinition) { my.create_table_statements(:a, id: :nope) { } }
    end

    it "emits table and column comments per dialect" do
      body = ->(t : Grant::Schema::TableDefinition) { t.string :name, comment: "Display name" }
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02a_c, comment: "People") { |t| body.call(t) }.should eq [
        "CREATE TABLE \"m02a_c\" (\n  \"id\" BIGSERIAL PRIMARY KEY,\n  \"name\" VARCHAR\n)",
        "COMMENT ON TABLE \"m02a_c\" IS 'People'",
        "COMMENT ON COLUMN \"m02a_c\".\"name\" IS 'Display name'",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_table_statements(:m02a_c, comment: "People") { |t| body.call(t) }.should eq [
        "CREATE TABLE `m02a_c` (\n  `id` BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,\n  `name` VARCHAR(255) COMMENT 'Display name'\n) COMMENT='People'",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).create_table_statements(:m02a_c, comment: "People") { |t| body.call(t) }.size.should eq 1
    end

    it "emits collation, array and raw types" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.create_table_statements(:a, id: false) { |t| t.string :n, collation: "C"; t.text :tags, array: true; t.column :e, "citext" }.first
        .should eq "CREATE TABLE \"a\" (\n  \"n\" VARCHAR COLLATE \"C\",\n  \"tags\" TEXT[],\n  \"e\" citext\n)"
      lite = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      lite.create_table_statements(:a, id: false) { |t| t.string :n, collation: "NOCASE" }.first.should contain "\"n\" VARCHAR(255) COLLATE NOCASE"
      expect_raises(Grant::Schema::UnsupportedOperation) { lite.create_table_statements(:a) { |t| t.text :tags, array: true } }
    end

    it "rejects duplicate columns and conflicting defaults" do
      rec = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      expect_raises(Grant::Schema::InvalidDefinition) { rec.create_table_statements(:a) { |t| t.string :n; t.string :n } }
      expect_raises(Grant::Schema::InvalidDefinition) { rec.create_table_statements(:a) { |t| t.string :n, default: "x", default_sql: "lower('x')" } }
    end
  end

  describe "drop_table_statements" do
    it "supports if_exists and cascade" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.drop_table_statements(:a, :b, if_exists: true, cascade: true).should eq ["DROP TABLE IF EXISTS \"a\" CASCADE", "DROP TABLE IF EXISTS \"b\" CASCADE"]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).drop_table_statements(:a).should eq ["DROP TABLE `a`"]
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)

    after_each { statements.drop_table(:m02a_live, :m02a_live_tmp, if_exists: true) }

    it "creates, forces and drops a real table" do
      statements.drop_table(:m02a_live, if_exists: true)
      statements.create_table(:m02a_live, comment: "Live") do |t|
        t.string :name, null: false
        t.timestamps
      end
      SchemaFixture.adapter.schema.table_exists?(:m02a_live).should be_true
      expect_raises(Grant::ErrorBase) { statements.create_table(:m02a_live, &.integer(:n)) }
      statements.create_table(:m02a_live, if_not_exists: true) { |t| t.integer :n }
      statements.create_table(:m02a_live, force: true) { |t| t.integer :n }
      SchemaFixture.adapter.schema.columns(:m02a_live).map(&.name).should eq ["id", "n"]
      statements.drop_table(:m02a_live)
      SchemaFixture.adapter.schema.table_exists?(:m02a_live).should be_false
    end

    it "creates a join table without an id" do
      statements.create_table(:m02a_live, id: false) do |t|
        t.bigint :a_id, null: false
        t.bigint :b_id, null: false
      end
      SchemaFixture.adapter.schema.columns(:m02a_live).map(&.name).should eq ["a_id", "b_id"]
      SchemaFixture.adapter.schema.columns(:m02a_live).none?(&.primary_key?).should be_true
    end

    it "creates a temporary table" do
      # A temporary table lives on one connection, so create and use it on one.
      sql = Grant::Schema::RecordingStatements.new(statements.dialect).create_table_statements(:m02a_live_tmp, temporary: true) { |t| t.integer :n }
      SchemaFixture.adapter.open do |db|
        sql.each { |statement| db.exec statement }
        db.exec "INSERT INTO m02a_live_tmp (n) VALUES (1)"
        db.scalar("SELECT COUNT(*) FROM m02a_live_tmp").should eq 1
      end
    end
  end
end
