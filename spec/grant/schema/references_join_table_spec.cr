require "../../support/schema_fixture"

describe "M02b references and join tables" do
  describe "SQL per dialect" do
    it "derives the join table name and columns" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_join_table_statements(:users, :groups)
      sql.should eq ["CREATE TABLE \"groups_users\" (\n  \"user_id\" BIGINT NOT NULL,\n  \"group_id\" BIGINT NOT NULL\n)"]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).create_join_table_statements(:categories, :posts, column_options: {null: true}).first
        .should eq "CREATE TABLE `categories_posts` (\n  `category_id` BIGINT,\n  `post_id` BIGINT\n)"
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).drop_join_table_statements(:users, :groups).should eq ["DROP TABLE \"groups_users\""]
    end

    it "adds a join table with an index through the block" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_join_table_statements(:users, :groups, table_name: :memberships) do |t|
        t.index [:user_id, :group_id], unique: true
      end
      sql.last.should eq "CREATE UNIQUE INDEX \"index_memberships_on_user_id_and_group_id\" ON \"memberships\" (\"user_id\", \"group_id\")"
    end

    it "builds reference columns, index and foreign key for create_table" do
      sql = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).create_table_statements(:m02b_posts) do |t|
        t.references :user, foreign_key: true
        t.references :commentable, polymorphic: true
        t.references :editor, foreign_key: {to_table: :users, on_delete: :nullify}
      end
      sql.first.should contain "\"user_id\" BIGINT"
      sql.first.should contain "\"commentable_type\" VARCHAR"
      sql.first.should contain "CONSTRAINT \"fk_m02b_posts_user_id\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\")"
      sql.first.should contain "CONSTRAINT \"fk_m02b_posts_editor_id\" FOREIGN KEY (\"editor_id\") REFERENCES \"users\" (\"id\") ON DELETE SET NULL"
      sql.first.should_not contain "REFERENCES \"commentables\""
      sql.should contain "CREATE INDEX \"index_m02b_posts_on_commentable_type_and_commentable_id\" ON \"m02b_posts\" (\"commentable_type\", \"commentable_id\")"
      sql.should contain "CREATE INDEX \"index_m02b_posts_on_user_id\" ON \"m02b_posts\" (\"user_id\")"
    end

    it "adds and removes a reference on an existing table" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_reference_statements(:posts, :user, foreign_key: true).should eq [
        "ALTER TABLE \"posts\" ADD COLUMN \"user_id\" BIGINT",
        "CREATE INDEX \"index_posts_on_user_id\" ON \"posts\" (\"user_id\")",
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_user_id\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\")",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite).add_reference_statements(:posts, :user, foreign_key: true, index: false).should eq [
        "ALTER TABLE \"posts\" ADD COLUMN \"user_id\" BIGINT REFERENCES \"users\" (\"id\")",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).remove_reference_statements(:posts, :user, foreign_key: true).should eq [
        "ALTER TABLE `posts` DROP FOREIGN KEY `fk_posts_user_id`",
        "ALTER TABLE `posts` DROP COLUMN `user_id`",
      ]
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_rf_posts, :m02b_rf_editors, :m02b_rf_groups, :m02b_rf_editors_m02b_rf_groups, if_exists: true)
      statements.create_table(:m02b_rf_editors, &.string(:name))
      statements.create_table(:m02b_rf_posts, &.string(:title))
    end
    after_each { statements.drop_table(:m02b_rf_posts, :m02b_rf_editors, :m02b_rf_groups, :m02b_rf_editors_m02b_rf_groups, if_exists: true) }

    it "creates and drops a join table" do
      statements.create_join_table(:m02b_rf_editors, :m02b_rf_groups)
      name = "m02b_rf_editors_m02b_rf_groups"
      schema.columns(name).map(&.name).should eq ["m02b_rf_editor_id", "m02b_rf_group_id"]
      schema.columns(name).none?(&.null?).should be_true
      statements.drop_join_table(:m02b_rf_editors, :m02b_rf_groups)
      schema.table_exists?(name).should be_false
    end

    it "adds a reference with an index and a foreign key" do
      statements.add_reference(:m02b_rf_posts, :m02b_rf_editor, foreign_key: {to_table: :m02b_rf_editors})
      schema.columns(:m02b_rf_posts).map(&.name).should eq ["id", "title", "m02b_rf_editor_id"]
      schema.index_exists?(:m02b_rf_posts, ["m02b_rf_editor_id"] of String | Symbol).should be_true
      schema.foreign_key_exists?(:m02b_rf_posts, :m02b_rf_editors).should be_true
      SchemaFixture.exec "INSERT INTO m02b_rf_editors (name) VALUES ('e')"
      SchemaFixture.exec "INSERT INTO m02b_rf_posts (title, m02b_rf_editor_id) VALUES ('t', 1)"
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_rf_posts (title, m02b_rf_editor_id) VALUES ('t', 99)" }
    end

    it "adds a polymorphic reference with a composite index and no key" do
      statements.add_reference(:m02b_rf_posts, :owner, polymorphic: true)
      schema.columns(:m02b_rf_posts).map(&.name).should eq ["id", "title", "owner_id", "owner_type"]
      schema.indexes(:m02b_rf_posts).map(&.columns).should eq [["owner_type", "owner_id"]]
      schema.foreign_keys(:m02b_rf_posts).should be_empty
    end

    it "removes a reference with its column, index and foreign key" do
      statements.add_reference(:m02b_rf_posts, :m02b_rf_editor, foreign_key: {to_table: :m02b_rf_editors})
      statements.remove_reference(:m02b_rf_posts, :m02b_rf_editor, foreign_key: true)
      schema.columns(:m02b_rf_posts).map(&.name).should eq ["id", "title"]
      schema.indexes(:m02b_rf_posts).should be_empty
      schema.foreign_keys(:m02b_rf_posts).should be_empty
    end

    it "creates references in create_table" do
      statements.create_table(:m02b_rf_posts, force: true) do |t|
        t.references :m02b_rf_editor, foreign_key: {to_table: :m02b_rf_editors, on_delete: :cascade}, null: false
        t.references :commentable, polymorphic: true
      end
      schema.foreign_keys(:m02b_rf_posts).first.on_delete.should eq Grant::Schema::ReferentialAction::Cascade
      schema.columns(:m02b_rf_posts).find!(&.name.== "m02b_rf_editor_id").null?.should be_false
      schema.indexes(:m02b_rf_posts).size.should eq 2
    end
  end
end
