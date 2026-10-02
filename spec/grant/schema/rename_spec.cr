require "../../support/schema_fixture"

private def m02b_rename_scalar(sql : String)
  SchemaFixture.adapter.open(&.scalar(sql))
end

describe "M02b renames" do
  describe "SQL per dialect" do
    it "renames a table, its PostgreSQL sequence and key index, and default-named indexes" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.known_indexes["users"] = [Grant::Schema::IndexInfo.new("users", "index_users_on_email", ["email"]), Grant::Schema::IndexInfo.new("users", "custom", ["x"])]
      pg.rename_table_statements(:users, :accounts).should eq [
        "ALTER TABLE \"users\" RENAME TO \"accounts\"",
        "ALTER SEQUENCE IF EXISTS \"users_id_seq\" RENAME TO \"accounts_id_seq\"",
        "ALTER INDEX IF EXISTS \"users_pkey\" RENAME TO \"accounts_pkey\"",
        "ALTER INDEX \"index_users_on_email\" RENAME TO \"index_accounts_on_email\"",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).rename_table_statements(:users, :accounts)
        .should eq ["RENAME TABLE `users` TO `accounts`"]
    end

    it "renames a column and the indexes that carry its default name" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.known_indexes["users"] = [Grant::Schema::IndexInfo.new("users", "index_users_on_name", ["name"]), Grant::Schema::IndexInfo.new("users", "custom", ["name"])]
      pg.rename_column_statements(:users, :name, :full_name).should eq [
        "ALTER TABLE \"users\" RENAME COLUMN \"name\" TO \"full_name\"",
        "ALTER INDEX \"index_users_on_name\" RENAME TO \"index_users_on_full_name\"",
      ]
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_rn, :m02b_rn_renamed, if_exists: true)
      statements.create_table(:m02b_rn) do |t|
        t.string :name
        t.string :city
        t.index :name
        t.index [:name, :city]
        t.index :city, name: "m02b_custom_city"
      end
      SchemaFixture.exec "INSERT INTO m02b_rn (name, city) VALUES ('n', 'c')"
    end
    after_each { statements.drop_table(:m02b_rn, :m02b_rn_renamed, if_exists: true) }

    it "renames a table and keeps its rows, key and default-named indexes" do
      statements.rename_table(:m02b_rn, :m02b_rn_renamed)
      schema.table_exists?(:m02b_rn).should be_false
      schema.table_exists?(:m02b_rn_renamed).should be_true
      m02b_rename_scalar("SELECT name FROM m02b_rn_renamed").should eq "n"
      names = schema.indexes(:m02b_rn_renamed).map(&.name).sort!
      names.should eq ["index_m02b_rn_renamed_on_name", "index_m02b_rn_renamed_on_name_and_city", "m02b_custom_city"]
    end

    it "renames the PostgreSQL key sequence and index so inserts still work" do
      statements.rename_table(:m02b_rn, :m02b_rn_renamed)
      SchemaFixture.exec "INSERT INTO m02b_rn_renamed (name) VALUES ('second')"
      m02b_rename_scalar("SELECT id FROM m02b_rn_renamed WHERE name = 'second'").should eq 2
      next unless CURRENT_ADAPTER == "pg"
      m02b_rename_scalar("SELECT COUNT(*) FROM pg_class WHERE relname = 'm02b_rn_renamed_id_seq'").should eq 1
      m02b_rename_scalar("SELECT COUNT(*) FROM pg_class WHERE relname = 'm02b_rn_renamed_pkey'").should eq 1
      m02b_rename_scalar("SELECT COUNT(*) FROM pg_class WHERE relname IN ('m02b_rn_id_seq', 'm02b_rn_pkey')").should eq 0
    end

    it "renames a column and the indexes named after it" do
      statements.rename_column(:m02b_rn, :name, :full_name)
      schema.columns(:m02b_rn).map(&.name).should eq ["id", "full_name", "city"]
      m02b_rename_scalar("SELECT full_name FROM m02b_rn").should eq "n"
      schema.indexes(:m02b_rn).map(&.name).sort!.should eq ["index_m02b_rn_on_full_name", "index_m02b_rn_on_full_name_and_city", "m02b_custom_city"]
      schema.indexes(:m02b_rn).find!(&.name.== "index_m02b_rn_on_full_name_and_city").columns.should eq ["full_name", "city"]
    end

    it "renames a column inside change_table" do
      statements.change_table(:m02b_rn, &.rename(:city, :town))
      schema.columns(:m02b_rn).map(&.name).should eq ["id", "name", "town"]
    end

    it "renames an index" do
      statements.rename_index(:m02b_rn, "m02b_custom_city", "m02b_other")
      schema.index_exists?(:m02b_rn, name: "m02b_other").should be_true
      schema.index_exists?(:m02b_rn, name: "m02b_custom_city").should be_false
    end
  end
end
