require "../../support/schema_fixture"

describe "M02b table and column comments" do
  describe "SQL per dialect" do
    it "comments a table on PostgreSQL and MySQL and skips SQLite" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).change_table_comment_statements(:users, "Accounts")
        .should eq ["COMMENT ON TABLE \"users\" IS 'Accounts'"]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).change_table_comment_statements(:users, nil)
        .should eq ["COMMENT ON TABLE \"users\" IS NULL"]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).change_table_comment_statements(:users, "Accounts")
        .should eq ["ALTER TABLE `users` COMMENT = 'Accounts'"]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).change_table_comment_statements(:users, "Accounts").should be_empty
    end

    it "comments a column, restating it on MySQL" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).change_column_comment_statements(:users, :age, "Years")
        .should eq ["COMMENT ON COLUMN \"users\".\"age\" IS 'Years'"]
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      my.known_columns["users"] = [Grant::Schema::ColumnInfo.new("users", "age", "int", false, "0")]
      my.change_column_comment_statements(:users, :age, "Years")
        .should eq ["ALTER TABLE `users` MODIFY COLUMN `age` int NOT NULL DEFAULT 0 COMMENT 'Years'"]
      expect_raises(Grant::Schema::UnsupportedOperation) do
        Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).change_column_comment_statements(:users, :age, "Years")
      end
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).change_column_comment_statements(:users, :age, "Years").should be_empty
    end

    it "escapes quotes in comments" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).change_table_comment_statements(:users, "Bob's table")
        .should eq ["COMMENT ON TABLE \"users\" IS 'Bob''s table'"]
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_cm, if_exists: true)
      statements.create_table(:m02b_cm) { |t| t.integer :age }
    end
    after_each { statements.drop_table(:m02b_cm, if_exists: true) }

    it "sets, reads and clears comments where the database has them" do
      statements.change_table_comment(:m02b_cm, "Accounts")
      statements.change_column_comment(:m02b_cm, :age, "Years")
      if CURRENT_ADAPTER == "sqlite"
        # SQLite has no comments: the calls are accepted and do nothing.
        schema.table_comment(:m02b_cm).should be_nil
        schema.columns(:m02b_cm).find!(&.name.== "age").comment.should be_nil
      else
        schema.table_comment(:m02b_cm).should eq "Accounts"
        schema.columns(:m02b_cm).find!(&.name.== "age").comment.should eq "Years"
        statements.change_table_comment(:m02b_cm, nil)
        statements.change_column_comment(:m02b_cm, :age, nil)
        schema.table_comment(:m02b_cm).should be_nil
        schema.columns(:m02b_cm).find!(&.name.== "age").comment.to_s.should eq ""
      end
    end

    it "sets comments from create_table, add_column and change_table" do
      statements.create_table(:m02b_cm, force: true, comment: "Made") { |t| t.string :name, comment: "Label" }
      statements.add_column(:m02b_cm, :score, :integer, comment: "Points")
      statements.change_table(:m02b_cm) { |t| t.comment "Changed" }
      next if CURRENT_ADAPTER == "sqlite"
      schema.table_comment(:m02b_cm).should eq "Changed"
      schema.columns(:m02b_cm).map { |column| {column.name, column.comment} }.reject { |pair| pair[0] == "id" }
        .should eq [{"name", "Label"}, {"score", "Points"}]
    end
  end
end
