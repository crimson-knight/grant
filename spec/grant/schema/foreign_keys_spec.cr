require "../../support/schema_fixture"

describe "M02b foreign keys" do
  describe "SQL per dialect" do
    it "adds a foreign key with the conventional column, key and name" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_foreign_key_statements(:posts, :users).should eq [
        "ALTER TABLE \"posts\" ADD CONSTRAINT \"fk_posts_user_id\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\")",
      ]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).add_foreign_key_statements(:posts, :users, column: :author_id, on_delete: :cascade, on_update: :restrict, name: "fk_a")
        .should eq ["ALTER TABLE `posts` ADD CONSTRAINT `fk_a` FOREIGN KEY (`author_id`) REFERENCES `users` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT"]
    end

    it "adds NOT VALID then validates on PostgreSQL, and ignores validate elsewhere" do
      pg = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
      pg.add_foreign_key_statements(:posts, :users, validate: false, deferrable: :deferred).first
        .should end_with "DEFERRABLE INITIALLY DEFERRED NOT VALID"
      pg.validate_foreign_key_statements(:posts, :users).should eq ["ALTER TABLE \"posts\" VALIDATE CONSTRAINT \"fk_posts_user_id\""]
      my = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql)
      my.add_foreign_key_statements(:posts, :users, validate: false).first.should_not contain "NOT VALID"
      my.validate_foreign_key_statements(:posts, :users).should be_empty
      expect_raises(Grant::Schema::UnsupportedOperation) { my.add_foreign_key_statements(:posts, :users, deferrable: true) }
    end

    it "drops a foreign key per dialect" do
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).remove_foreign_key_statements(:posts, :users, if_exists: true)
        .should eq ["ALTER TABLE \"posts\" DROP CONSTRAINT IF EXISTS \"fk_posts_user_id\""]
      Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Mysql).remove_foreign_key_statements(:posts, name: "fk_x")
        .should eq ["ALTER TABLE `posts` DROP FOREIGN KEY `fk_x`"]
    end

    it "declares foreign keys in create_table" do
      rec = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Sqlite)
      rec.create_table_statements(:posts) do |t|
        t.bigint :user_id
        t.foreign_key :users, on_delete: :nullify
      end.first.should contain "CONSTRAINT \"fk_posts_user_id\" FOREIGN KEY (\"user_id\") REFERENCES \"users\" (\"id\") ON DELETE SET NULL"
    end

    it "rejects unknown actions" do
      expect_raises(Grant::Schema::InvalidDefinition) { Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg).add_foreign_key_statements(:a, :b, on_delete: :explode) }
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_fk_child, :m02b_fk_parent, if_exists: true)
      statements.create_table(:m02b_fk_parent) { |t| t.string :name }
      statements.create_table(:m02b_fk_child) do |t|
        t.bigint :m02b_fk_parent_id
        t.string :note, null: false, default: "x"
      end
      SchemaFixture.exec "INSERT INTO m02b_fk_parent (name) VALUES ('p')"
    end
    after_each { statements.drop_table(:m02b_fk_child, :m02b_fk_parent, if_exists: true) }

    it "adds a foreign key with on_delete and reads it back" do
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, on_delete: :cascade, on_update: :restrict)
      key = schema.foreign_keys(:m02b_fk_child).first
      key.to_table.should eq "m02b_fk_parent"
      key.columns.should eq ["m02b_fk_parent_id"]
      key.on_delete.should eq Grant::Schema::ReferentialAction::Cascade
      key.on_update.should eq Grant::Schema::ReferentialAction::Restrict
      schema.foreign_key_exists?(:m02b_fk_child, :m02b_fk_parent).should be_true
    end

    it "enforces the key and cascades the delete" do
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, on_delete: :cascade)
      SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id) VALUES (1)"
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id) VALUES (999)" }
      SchemaFixture.exec "DELETE FROM m02b_fk_parent WHERE id = 1"
      SchemaFixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m02b_fk_child").should eq 0 }
    end

    it "keeps rows and other columns through the SQLite rebuild" do
      SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id, note) VALUES (1, 'kept')"
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
      SchemaFixture.adapter.open { |db| db.scalar("SELECT note FROM m02b_fk_child").should eq "kept" }
      schema.columns(:m02b_fk_child).map(&.name).should eq ["id", "m02b_fk_parent_id", "note"]
      schema.columns(:m02b_fk_child).find!(&.name.== "note").null?.should be_false
    end

    it "adds NOT VALID then validates on PostgreSQL, checks existing rows on MySQL" do
      SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id) VALUES (999)"
      if CURRENT_ADAPTER == "pg"
        statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, validate: false)
        SchemaFixture.adapter.open { |db| db.scalar("SELECT convalidated FROM pg_constraint WHERE conname = 'fk_m02b_fk_child_m02b_fk_parent_id'").should eq false }
        expect_raises(Exception) { statements.validate_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id) }
        SchemaFixture.exec "DELETE FROM m02b_fk_child"
        statements.validate_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
        SchemaFixture.adapter.open { |db| db.scalar("SELECT convalidated FROM pg_constraint WHERE conname = 'fk_m02b_fk_child_m02b_fk_parent_id'").should eq true }
      elsif CURRENT_ADAPTER == "mysql"
        expect_raises(Exception) { statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id) }
      else
        # SQLite copies rows into the rebuilt table without checking the new key,
        # as ActiveRecord's table rebuild does.
        statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
        schema.foreign_keys(:m02b_fk_child).size.should eq 1
      end
    end

    it "removes a foreign key and honors if_exists" do
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
      statements.remove_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
      schema.foreign_keys(:m02b_fk_child).should be_empty
      statements.remove_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, if_exists: true)
      SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id) VALUES (999)"
    end

    it "skips an existing foreign key with if_not_exists" do
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id)
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, if_not_exists: true)
      schema.foreign_keys(:m02b_fk_child).size.should eq 1
    end

    it "rebuilds a table that other tables reference without losing their rows" do
      statements.add_foreign_key(:m02b_fk_child, :m02b_fk_parent, column: :m02b_fk_parent_id, on_delete: :cascade)
      SchemaFixture.exec "INSERT INTO m02b_fk_child (m02b_fk_parent_id) VALUES (1)"
      # Changing the parent rebuilds it on SQLite; the child must survive.
      statements.add_check_constraint(:m02b_fk_parent, "length(name) > 0", name: "m02b_fk_parent_name")
      SchemaFixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m02b_fk_child").should eq 1 }
      schema.foreign_keys(:m02b_fk_child).size.should eq 1
    end
  end
end
