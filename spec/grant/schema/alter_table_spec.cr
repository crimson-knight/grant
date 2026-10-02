require "../../support/schema_fixture"

private def m02b_scalar(sql : String)
  SchemaFixture.adapter.open(&.scalar(sql))
end

describe "M02b alter table" do
  describe "SQL per dialect" do
    it "adds and removes columns" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_column_statements(:users, :age, :integer, null: false, default: 0, if_not_exists: true)
        .should eq ["ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"age\" INTEGER NOT NULL DEFAULT 0"]
      pg.remove_column_statements(:users, :age, :integer, if_exists: true).should eq ["ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"age\""]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).add_column_statements(:users, :age, :integer, comment: "Years")
        .should eq ["ALTER TABLE `users` ADD COLUMN `age` INT COMMENT 'Years'"]
      pg.add_column_statements(:users, :age, :integer, comment: "Years").last.should eq "COMMENT ON COLUMN \"users\".\"age\" IS 'Years'"
      expect_raises(Grant::Schema::UnsupportedOperation) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).add_column_statements(:users, :age, :integer, null: false)
      end
    end

    it "changes a column type, null and default on PostgreSQL in one ALTER" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.change_column_statements(:users, :age, :bigint, null: false, default: 0, using: "age::bigint").should eq [
        "ALTER TABLE \"users\" ALTER COLUMN \"age\" TYPE BIGINT USING age::bigint, ALTER COLUMN \"age\" SET NOT NULL, ALTER COLUMN \"age\" SET DEFAULT 0",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).change_column_statements(:users, :age, :bigint, null: false)
        .should eq ["ALTER TABLE `users` MODIFY COLUMN `age` BIGINT NOT NULL"]
    end

    it "backfills before it forbids NULL" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.change_column_null_statements(:users, :email, false, default: "").should eq [
        "UPDATE \"users\" SET \"email\" = '' WHERE \"email\" IS NULL",
        "ALTER TABLE \"users\" ALTER COLUMN \"email\" SET NOT NULL",
      ]
      pg.change_column_null_statements(:users, :email, true).should eq ["ALTER TABLE \"users\" ALTER COLUMN \"email\" DROP NOT NULL"]
    end

    it "combines bulk changes into one ALTER" do
      build = ->(dialect : Grant::Schema::Dialect, bulk : Bool) do
        Grant::Schema::RecordingStatements.new(dialect).change_table_statements(:users, bulk: bulk) do |t|
          t.string :nickname
          t.integer :age
          t.remove :legacy
        end
      end
      build.call(Grant::Schema::Dialect::Pg, true).should eq [
        "ALTER TABLE \"users\" ADD COLUMN \"nickname\" VARCHAR, ADD COLUMN \"age\" INTEGER, DROP COLUMN \"legacy\"",
      ]
      build.call(Grant::Schema::Dialect::Pg, false).size.should eq 3
      build.call(Grant::Schema::Dialect::Mysql, true).should eq [
        "ALTER TABLE `users` ADD COLUMN `nickname` VARCHAR(255), ADD COLUMN `age` INT, DROP COLUMN `legacy`",
      ]
    end

    it "rebuilds a SQLite table once for several changes" do
      lite = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      lite.sqlite_tables["users"] = {"CREATE TABLE \"users\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, \"name\" VARCHAR(255), \"legacy\" TEXT)", [] of String}
      sql = lite.change_table_statements(:users, bulk: true) do |t|
        t.remove :legacy
        t.change_null :name, false, default: "anon"
        t.string :nickname
      end
      sql.count(&.starts_with?("CREATE TABLE")).should eq 1
      sql.first.should eq "UPDATE \"users\" SET \"name\" = 'anon' WHERE \"name\" IS NULL"
      sql.should contain "PRAGMA foreign_keys = OFF"
      sql.find!(&.starts_with?("CREATE TABLE")).should eq "CREATE TABLE \"__grant_rebuild_users\" (\n  \"id\" INTEGER PRIMARY KEY AUTOINCREMENT,\n  \"name\" VARCHAR(255) NOT NULL,\n  \"nickname\" VARCHAR(255)\n)"
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_at, if_exists: true)
      statements.create_table(:m02b_at) do |t|
        t.string :email
        t.integer :score, default: 1
        t.string :legacy
      end
      SchemaFixture.exec "INSERT INTO m02b_at (email, score, legacy) VALUES (NULL, 7, 'old')"
      SchemaFixture.exec "INSERT INTO m02b_at (email, score, legacy) VALUES ('a@x', 8, 'old')"
    end
    after_each { statements.drop_table(:m02b_at, if_exists: true) }

    it "adds a column with a default, if_not_exists, and reads it back" do
      statements.add_column(:m02b_at, :age, :integer, null: false, default: 3)
      statements.add_column(:m02b_at, :age, :integer, null: false, default: 3, if_not_exists: true)
      info = schema.columns(:m02b_at).find!(&.name.== "age")
      info.null?.should be_false
      m02b_scalar("SELECT age FROM m02b_at WHERE score = 7").should eq 3
      expect_raises(Exception) { statements.add_column(:m02b_at, :age, :integer) }
    end

    it "adds a column with an expression default" do
      statements.add_column(:m02b_at, :seen_at, :datetime, null: false, default_sql: "CURRENT_TIMESTAMP")
      m02b_scalar("SELECT COUNT(seen_at) FROM m02b_at").should eq 2
    end

    it "removes a column, also when an index uses it" do
      statements.add_index(:m02b_at, :legacy)
      statements.remove_column(:m02b_at, :legacy, :string)
      schema.columns(:m02b_at).map(&.name).should eq ["id", "email", "score"]
      schema.indexes(:m02b_at).should be_empty
      m02b_scalar("SELECT COUNT(*) FROM m02b_at").should eq 2
      statements.remove_column(:m02b_at, :legacy, if_exists: true)
    end

    it "changes a column type and keeps the data" do
      statements.change_column(:m02b_at, :score, :bigint)
      m02b_scalar("SELECT SUM(score) FROM m02b_at").to_s.to_f.to_i.should eq 15
      schema.columns(:m02b_at).find!(&.name.== "score").sql_type.downcase.should contain(CURRENT_ADAPTER == "sqlite" ? "bigint" : "bigint")
    end

    it "sets NOT NULL after backfilling NULLs with a default" do
      expect_raises(Exception) { statements.change_column_null(:m02b_at, :email, false) }
      statements.change_column_null(:m02b_at, :email, false, default: "nobody")
      schema.columns(:m02b_at).find!(&.name.== "email").null?.should be_false
      m02b_scalar("SELECT email FROM m02b_at WHERE score = 7").should eq "nobody"
      statements.change_column_null(:m02b_at, :email, true)
      schema.columns(:m02b_at).find!(&.name.== "email").null?.should be_true
    end

    it "keeps the default and NOT NULL when changing only the type" do
      statements.change_column_null(:m02b_at, :score, false)
      statements.change_column(:m02b_at, :score, :bigint)
      info = schema.columns(:m02b_at).find!(&.name.== "score")
      info.null?.should be_false
      info.default.to_s.should contain "1"
    end

    it "applies bulk: true as one statement on PostgreSQL and MySQL and one rebuild on SQLite" do
      statements.change_table(:m02b_at, bulk: true) do |t|
        t.string :nickname
        t.remove :legacy
        t.change_null :email, false, default: "anon"
      end
      schema.columns(:m02b_at).map(&.name).should eq ["id", "email", "score", "nickname"]
      m02b_scalar("SELECT COUNT(*) FROM m02b_at WHERE email = 'anon'").should eq 1
    end

    it "changes the default in place" do
      next if CURRENT_ADAPTER == "sqlite"
      statements.change_column_default(:m02b_at, :score, to: 42)
      SchemaFixture.exec "INSERT INTO m02b_at (email) VALUES ('d')"
      m02b_scalar("SELECT score FROM m02b_at WHERE email = 'd'").should eq 42
    end
  end
end
