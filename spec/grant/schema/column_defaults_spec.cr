require "../../support/schema_fixture"
require "../../support/test_connection"

class M02aDefaultRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table m02a_default_rows

  column id : Int64, primary: true
  column token : String?, default_sql: "lower('ABC')"
  column total : Int32?, default_sql: "1 + 2"
  column stamped : Time?, default_sql: "CURRENT_TIMESTAMP"
  column role : String? = "member"
end

describe "Column defaults" do
  describe "SQL expression defaults per dialect" do
    it "emits expressions the way each database needs them" do
      build = ->(dialect : Grant::Schema::Dialect) do
        Grant::Schema::RecordingStatements.new(dialect).create_table_statements(:m02a_expr, id: false) do |t|
          t.datetime :created_at, default_sql: "CURRENT_TIMESTAMP"
          t.string :token, default_sql: "lower('X')"
          t.integer :n, default: 5
          t.string :role, default: "it's"
          t.boolean :on, default: false
          t.string :nothing, default: nil
        end.first
      end
      pg = build.call(Grant::Schema::Dialect::Pg)
      pg.should contain %("created_at" TIMESTAMP(6) DEFAULT CURRENT_TIMESTAMP)
      pg.should contain %("token" VARCHAR DEFAULT lower('X'))
      pg.should contain %("n" INTEGER DEFAULT 5)
      pg.should contain %("role" VARCHAR DEFAULT 'it''s')
      pg.should contain %("on" BOOLEAN DEFAULT FALSE)
      pg.should contain %("nothing" VARCHAR DEFAULT NULL)
      my = build.call(Grant::Schema::Dialect::Mysql)
      my.should contain "`created_at` DATETIME(6) DEFAULT CURRENT_TIMESTAMP"
      my.should contain "`token` VARCHAR(255) DEFAULT (lower('X'))"
      lite = build.call(Grant::Schema::Dialect::Sqlite)
      lite.should contain %("created_at" DATETIME DEFAULT CURRENT_TIMESTAMP)
      lite.should contain %("token" VARCHAR(255) DEFAULT (lower('X')))
    end

    it "keeps user parentheses and MySQL precision timestamps" do
      dialect = Grant::Schema::Dialect::Mysql
      dialect.default_expression("CURRENT_TIMESTAMP(6)").should eq "CURRENT_TIMESTAMP(6)"
      dialect.default_expression("(uuid())").should eq "(uuid())"
      Grant::Schema::Dialect::Pg.default_expression("gen_random_uuid()").should eq "gen_random_uuid()"
    end
  end

  describe "change_column_default" do
    it "emits the statement for PostgreSQL and MySQL" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.change_column_default_statements(:users, :role, from: nil, to: "member").should eq [
        "ALTER TABLE \"users\" ALTER COLUMN \"role\" SET DEFAULT 'member'",
      ]
      pg.change_column_default_statements(:users, :role, to: nil).should eq ["ALTER TABLE \"users\" ALTER COLUMN \"role\" DROP DEFAULT"]
      pg.change_column_default_statements(:users, :at, default_sql: "now()").should eq ["ALTER TABLE \"users\" ALTER COLUMN \"at\" SET DEFAULT now()"]
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      my.change_column_default_statements(:users, :role, to: 3).should eq ["ALTER TABLE `users` ALTER COLUMN `role` SET DEFAULT 3"]
      my.change_column_default_statements(:users, :at, default_sql: "lower('A')").should eq ["ALTER TABLE `users` ALTER COLUMN `at` SET DEFAULT (lower('A'))"]
    end

    it "needs a target, on SQLite too" do
      expect_raises(Grant::Schema::InvalidDefinition) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).change_column_default_statements(:users, :role)
      end
      expect_raises(Grant::Schema::InvalidDefinition) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).change_column_default_statements(:users, :role)
      end
    end
  end

  describe "on #{CURRENT_ADAPTER}" do
    before_each do
      TestConnection.ensure_registered
      M02aDefaultRow.migrator.drop_and_create
    end

    after_all { M02aDefaultRow.migrator.drop }

    it "emits default_sql and literal defaults from a model" do
      sql = M02aDefaultRow.migrator.create_sql
      sql.should contain "DEFAULT 'member'"
      case CURRENT_ADAPTER
      when "pg"
        sql.should contain "DEFAULT lower('ABC')"
        sql.should contain "DEFAULT 1 + 2"
      else
        sql.should contain "DEFAULT (lower('ABC'))"
        sql.should contain "DEFAULT (1 + 2)"
      end
      sql.should contain "DEFAULT CURRENT_TIMESTAMP"
    end

    it "applies the SQL defaults in the database" do
      insert = CURRENT_ADAPTER == "mysql" ? "INSERT INTO m02a_default_rows () VALUES ()" : "INSERT INTO m02a_default_rows DEFAULT VALUES"
      M02aDefaultRow.exec(insert)
      row = M02aDefaultRow.first!
      row.token.should eq "abc"
      row.total.should eq 3
      row.role.should eq "member"
      row.stamped.should_not be_nil
    end

    it "changes a default in place, or says why it cannot" do
      statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
      statements.change_column_default(:m02a_default_rows, :role, from: "member", to: "admin")
      insert = CURRENT_ADAPTER == "mysql" ? "INSERT INTO m02a_default_rows () VALUES ()" : "INSERT INTO m02a_default_rows DEFAULT VALUES"
      M02aDefaultRow.exec(insert)
      M02aDefaultRow.first!.role.should eq "admin"
      statements.change_column_default(:m02a_default_rows, :role, to: nil)
      SchemaFixture.adapter.schema.columns(:m02a_default_rows).find! { |column| column.name == "role" }.default.should be_nil
      statements.change_column_default(:m02a_default_rows, :total, default_sql: "2 * 5")
      M02aDefaultRow.exec(insert)
      M02aDefaultRow.order(id: :desc).first!.total.should eq 10
    end
  end
end
