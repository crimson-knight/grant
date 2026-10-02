require "../../support/schema_fixture"

private def m02b_index_recorder(dialect : Grant::Schema::Dialect)
  Grant::Schema::RecordingStatements.new(dialect)
end

describe "M02b indexes" do
  describe "SQL per dialect" do
    it "creates a plain, a unique and a multi-column index with the default name" do
      pg = m02b_index_recorder(Grant::Schema::Dialect::Pg)
      pg.add_index_statements(:users, :email).should eq ["CREATE INDEX \"index_users_on_email\" ON \"users\" (\"email\")"]
      pg.add_index_statements(:users, [:a, :b], unique: true).should eq ["CREATE UNIQUE INDEX \"index_users_on_a_and_b\" ON \"users\" (\"a\", \"b\")"]
      m02b_index_recorder(Grant::Schema::Dialect::Mysql).add_index_statements(:users, :email, name: "by_email")
        .should eq ["CREATE INDEX `by_email` ON `users` (`email`)"]
    end

    it "emits partial, using, order, opclass, include, concurrently and if_not_exists on PostgreSQL" do
      pg = m02b_index_recorder(Grant::Schema::Dialect::Pg)
      pg.add_index_statements(:users, :email, unique: true, where: "deleted_at IS NULL", if_not_exists: true)
        .should eq ["CREATE UNIQUE INDEX IF NOT EXISTS \"index_users_on_email\" ON \"users\" (\"email\") WHERE deleted_at IS NULL"]
      pg.add_index_statements(:docs, :body, using: :gin, name: "docs_body").should eq ["CREATE INDEX \"docs_body\" ON \"docs\" USING gin (\"body\")"]
      pg.add_index_statements(:users, [:name, :age], order: {name: :desc}, opclass: {name: "text_pattern_ops"}, include: :email)
        .should eq ["CREATE INDEX \"index_users_on_name_and_age\" ON \"users\" (\"name\" text_pattern_ops DESC, \"age\") INCLUDE (\"email\")"]
      pg.add_index_statements(:users, :email, algorithm: :concurrently)
        .should eq ["CREATE INDEX CONCURRENTLY \"index_users_on_email\" ON \"users\" (\"email\")"]
      pg.add_index_statements(:users, :email, comment: "lookup").last.should eq "COMMENT ON INDEX \"index_users_on_email\" IS 'lookup'"
    end

    it "needs a name for an expression index and wraps the expression" do
      pg = m02b_index_recorder(Grant::Schema::Dialect::Pg)
      expect_raises(Grant::Schema::InvalidDefinition) { pg.add_index_statements(:users, "lower(email)") }
      pg.add_index_statements(:users, "lower(email)", name: "users_lower_email")
        .should eq ["CREATE INDEX \"users_lower_email\" ON \"users\" ((lower(email)))"]
    end

    it "emits MySQL prefix length, fulltext and algorithm, and rejects what MySQL lacks" do
      my = m02b_index_recorder(Grant::Schema::Dialect::Mysql)
      my.add_index_statements(:posts, :title, length: 10).should eq ["CREATE INDEX `index_posts_on_title` ON `posts` (`title`(10))"]
      my.add_index_statements(:posts, :body, using: :fulltext).should eq ["CREATE FULLTEXT INDEX `index_posts_on_body` ON `posts` (`body`)"]
      my.add_index_statements(:posts, :title, algorithm: :inplace).should eq ["CREATE INDEX `index_posts_on_title` ON `posts` (`title`) ALGORITHM=INPLACE"]
      expect_raises(Grant::Schema::UnsupportedOperation) { my.add_index_statements(:posts, :title, where: "a > 1") }
      expect_raises(Grant::Schema::UnsupportedOperation) { my.add_index_statements(:posts, :title, if_not_exists: true) }
    end

    it "ignores concurrently on SQLite and rejects unsupported options" do
      lite = m02b_index_recorder(Grant::Schema::Dialect::Sqlite)
      lite.add_index_statements(:users, :email, algorithm: :concurrently, where: "a IS NULL")
        .should eq ["CREATE INDEX \"index_users_on_email\" ON \"users\" (\"email\") WHERE a IS NULL"]
      expect_raises(Grant::Schema::UnsupportedOperation) { lite.add_index_statements(:users, :email, include: :a) }
      expect_raises(Grant::Schema::UnsupportedOperation) { lite.add_index_statements(:users, :email, using: :gin) }
      expect_raises(Grant::Schema::InvalidDefinition) { lite.add_index_statements(:users, :email, name: "x" * 80) }
    end

    it "drops and renames indexes per dialect" do
      pg = m02b_index_recorder(Grant::Schema::Dialect::Pg)
      pg.remove_index_statements(:users, :email, if_exists: true, algorithm: :concurrently)
        .should eq ["DROP INDEX CONCURRENTLY IF EXISTS \"index_users_on_email\""]
      m02b_index_recorder(Grant::Schema::Dialect::Mysql).remove_index_statements(:users, name: "x").should eq ["DROP INDEX `x` ON `users`"]
      m02b_index_recorder(Grant::Schema::Dialect::Sqlite).remove_index_statements(:users, [:a, :b]).should eq ["DROP INDEX \"index_users_on_a_and_b\""]
      pg.rename_index_statements(:users, "a", "b").should eq ["ALTER INDEX \"a\" RENAME TO \"b\""]
      m02b_index_recorder(Grant::Schema::Dialect::Mysql).rename_index_statements(:users, "a", "b").should eq ["ALTER TABLE `users` RENAME INDEX `a` TO `b`"]
      expect_raises(Grant::Schema::InvalidDefinition) { pg.remove_index_statements(:users) }
    end

    it "creates indexes declared in create_table after the table" do
      pg = m02b_index_recorder(Grant::Schema::Dialect::Pg)
      sql = pg.create_table_statements(:m02b_t) do |t|
        t.string :email
        t.index :email, unique: true
      end
      sql.size.should eq 2
      sql.last.should eq "CREATE UNIQUE INDEX \"index_m02b_t_on_email\" ON \"m02b_t\" (\"email\")"
    end
  end

  describe "on the #{CURRENT_ADAPTER} database" do
    statements = Grant::Schema::AdapterStatements.new(SchemaFixture.adapter)
    schema = SchemaFixture.adapter.schema

    before_each do
      statements.drop_table(:m02b_ix, if_exists: true)
      statements.create_table(:m02b_ix) do |t|
        t.string :email, null: false
        t.string :name
        t.datetime :deleted_at
      end
    end
    after_each { statements.drop_table(:m02b_ix, if_exists: true) }

    it "round trips a unique partial index through introspection" do
      statements.add_index(:m02b_ix, :email, unique: true, where: "deleted_at IS NULL")
      info = schema.indexes(:m02b_ix).find! { |index| index.name == "index_m02b_ix_on_email" }
      info.unique?.should be_true
      info.columns.should eq ["email"]
      info.partial?.should be_true
      info.where.to_s.should contain "deleted_at IS NULL"
    end

    it "round trips a multi-column index and an expression index" do
      statements.add_index(:m02b_ix, [:email, :name])
      schema.index_exists?(:m02b_ix, [:email, :name] of String | Symbol).should be_true
      statements.add_index(:m02b_ix, "lower(email)", name: "m02b_ix_lower_email") unless CURRENT_ADAPTER == "mysql"
      unless CURRENT_ADAPTER == "mysql"
        expression = schema.indexes(:m02b_ix).find! { |index| index.name == "m02b_ix_lower_email" }
        expression.expression?.should be_true
      end
    end

    it "enforces uniqueness" do
      statements.add_index(:m02b_ix, :email, unique: true)
      SchemaFixture.exec "INSERT INTO m02b_ix (email) VALUES ('a@x')"
      expect_raises(Exception) { SchemaFixture.exec "INSERT INTO m02b_ix (email) VALUES ('a@x')" }
    end

    it "skips an existing index with if_not_exists and raises without it" do
      statements.add_index(:m02b_ix, :name)
      expect_raises(Exception) { statements.add_index(:m02b_ix, :name) }
      statements.add_index(:m02b_ix, :name, if_not_exists: true) unless CURRENT_ADAPTER == "mysql"
      schema.indexes(:m02b_ix).count { |index| index.columns == ["name"] }.should eq 1
    end

    it "removes an index by name, by columns, and with if_exists" do
      statements.add_index(:m02b_ix, :name)
      statements.remove_index(:m02b_ix, :name)
      schema.index_exists?(:m02b_ix, [:name] of String | Symbol).should be_false
      statements.remove_index(:m02b_ix, name: "nothing", if_exists: true)
      expect_raises(Exception) { statements.remove_index(:m02b_ix, name: "nothing") }
    end

    it "renames an index" do
      statements.add_index(:m02b_ix, :name, name: "m02b_ix_old")
      statements.rename_index(:m02b_ix, "m02b_ix_old", "m02b_ix_new")
      schema.index_exists?(:m02b_ix, name: "m02b_ix_new").should be_true
      schema.index_exists?(:m02b_ix, name: "m02b_ix_old").should be_false
    end

    it "builds a concurrent index on PostgreSQL and refuses it inside a transaction" do
      next unless CURRENT_ADAPTER == "pg"
      statements.add_index(:m02b_ix, :name, algorithm: :concurrently)
      schema.index_exists?(:m02b_ix, [:name] of String | Symbol).should be_true
      statements.remove_index(:m02b_ix, :name)
      expect_raises(Grant::Schema::InvalidDefinition) do
        statements.transaction { |tx| tx.add_index(:m02b_ix, :name, algorithm: :concurrently) }
      end
      schema.index_exists?(:m02b_ix, [:name] of String | Symbol).should be_false
      statements.transaction(disable_ddl_transaction: true) { |tx| tx.add_index(:m02b_ix, :name, algorithm: :concurrently) }
      schema.index_exists?(:m02b_ix, [:name] of String | Symbol).should be_true
    end

    it "creates indexes declared in create_table" do
      statements.create_table(:m02b_ix, force: true) do |t|
        t.string :email
        t.index :email, unique: true
      end
      schema.index_exists?(:m02b_ix, [:email] of String | Symbol, unique: true).should be_true
    end
  end
end
