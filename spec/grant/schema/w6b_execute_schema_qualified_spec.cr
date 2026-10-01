require "../../support/m03_fixture"

# Schema-qualified names (`namespace.table`) through every DSL call of a
# migration, plus raw `execute`, on a PostgreSQL schema, a MySQL database
# and a SQLite attached database.
module W6bQualified
  NS = "w6b_qual_ns"

  def self.adapter : Grant::Adapter::Base
    M03Fixture.adapter
  end

  def self.scalar(sql : String) : Int64
    adapter.open { |db| db.scalar(sql).as(Int).to_i64 }
  end

  def self.reset! : Nil
    case CURRENT_ADAPTER
    when "pg"
      adapter.open { |db| db.exec "DROP SCHEMA IF EXISTS #{NS} CASCADE" }
      adapter.open { |db| db.exec "CREATE SCHEMA #{NS}" }
    when "mysql"
      adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{NS}" }
      adapter.open { |db| db.exec "CREATE DATABASE #{NS}" }
    end
    adapter.reset_schema_caches!
  end

  def self.drop! : Nil
    case CURRENT_ADAPTER
    when "pg"    then adapter.open { |db| db.exec "DROP SCHEMA IF EXISTS #{NS} CASCADE" }
    when "mysql" then adapter.open { |db| db.exec "DROP DATABASE IF EXISTS #{NS}" }
    end
  end

  # Runs the block on one connection; on SQLite an in-memory database is
  # attached to it under NS first.
  def self.scoped(& : -> T) : T forall T
    adapter.with_connection do |connection|
      begin
        connection.exec "ATTACH DATABASE ':memory:' AS #{NS}" if CURRENT_ADAPTER == "sqlite"
        yield
      ensure
        connection.exec "DETACH DATABASE #{NS}" if CURRENT_ADAPTER == "sqlite"
      end
    end
  end

  def self.context(*classes : Grant::Schema::Migration.class) : Grant::Schema::MigrationContext
    Grant::Schema::MigrationContext.for(adapter, *classes, verbose: false)
  end
end

class W6bQualifiedCreate < Grant::Schema::Migration
  migration_version 20250101000001

  def up
    create_table "#{W6bQualified::NS}.w6b_items" do |t|
      t.string :label, null: false, default: "none"
      t.integer :qty, default: 0
      t.index :label
    end
    add_column "#{W6bQualified::NS}.w6b_items", :note, :string
    add_index "#{W6bQualified::NS}.w6b_items", :qty, name: "w6b_items_qty_idx"
    add_timestamps "#{W6bQualified::NS}.w6b_items", null: true
    execute "INSERT INTO #{W6bQualified::NS}.w6b_items (label, qty) VALUES ('first', 1)"
  end

  def down
    drop_table "#{W6bQualified::NS}.w6b_items"
  end
end

class W6bQualifiedAlter < Grant::Schema::Migration
  migration_version 20250101000002

  def up
    rename_column "#{W6bQualified::NS}.w6b_items", :note, :remark
    remove_index "#{W6bQualified::NS}.w6b_items", name: "w6b_items_qty_idx"
    remove_timestamps "#{W6bQualified::NS}.w6b_items"
    remove_column "#{W6bQualified::NS}.w6b_items", :remark
    rename_table "#{W6bQualified::NS}.w6b_items", "#{W6bQualified::NS}.w6b_things"
  end

  def down
    drop_table "#{W6bQualified::NS}.w6b_things"
  end
end

class W6bQualifiedJoin < Grant::Schema::Migration
  migration_version 20250101000003

  def up
    create_join_table "#{W6bQualified::NS}.w6b_left", "#{W6bQualified::NS}.w6b_right",
      table_name: "#{W6bQualified::NS}.w6b_left_w6b_right"
  end

  def down
    drop_table "#{W6bQualified::NS}.w6b_left_w6b_right"
  end
end

describe "schema-qualified table names and execute (#{CURRENT_ADAPTER})" do
  before_each do
    M03Fixture.reset!
    W6bQualified.reset!
  end

  after_all do
    M03Fixture.reset!
    W6bQualified.drop!
  end

  it "creates, extends, indexes and fills a qualified table through the runner" do
    W6bQualified.scoped do
      W6bQualified.context(W6bQualifiedCreate).migrate
      W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_items").should eq 1
      W6bQualified.scalar("SELECT qty FROM #{W6bQualified::NS}.w6b_items WHERE label = 'first'").should eq 1
      # The column added with add_column and the timestamps are there.
      W6bQualified.adapter.open { |db| db.exec "UPDATE #{W6bQualified::NS}.w6b_items SET note = 'n', created_at = NULL, updated_at = NULL" }
      # The default applies to a row that names no label.
      insert = CURRENT_ADAPTER == "mysql" ? "INSERT INTO #{W6bQualified::NS}.w6b_items () VALUES ()" : "INSERT INTO #{W6bQualified::NS}.w6b_items DEFAULT VALUES"
      W6bQualified.adapter.open { |db| db.exec insert }
      W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_items WHERE label = 'none'").should eq 1
      W6bQualified.scalar(index_count("w6b_items_qty_idx")).should eq 1
    end
  end

  it "renames, drops columns and indexes, renames the table and drops it" do
    W6bQualified.scoped do
      context = W6bQualified.context(W6bQualifiedCreate, W6bQualifiedAlter)
      context.migrate(20250101000001_i64)
      context.migrate(20250101000002_i64)
      W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_things").should eq 1
      expect_raises(Exception) { W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_items") }
      expect_raises(Exception) { W6bQualified.scalar("SELECT COUNT(remark) FROM #{W6bQualified::NS}.w6b_things") }
      W6bQualified.scalar(index_count("w6b_items_qty_idx")).should eq 0
      context.rollback
      expect_raises(Exception) { W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_things") }
    end
  end

  it "creates a qualified join table" do
    W6bQualified.scoped do
      W6bQualified.context(W6bQualifiedJoin).migrate
      W6bQualified.scalar("SELECT COUNT(*) FROM #{W6bQualified::NS}.w6b_left_w6b_right").should eq 0
      W6bQualified.context(W6bQualifiedJoin).rollback
    end
  end

  it "keeps the unqualified table of the same name apart from the qualified one" do
    W6bQualified.scoped do
      W6bQualified.context(W6bQualifiedCreate).migrate
      M03Fixture.table?("w6b_items").should be_false
    end
  end
end

# Number of indexes called *name* in the namespace, per dialect.
private def index_count(name : String) : String
  case CURRENT_ADAPTER
  when "pg"
    "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = '#{W6bQualified::NS}' AND indexname = '#{name}'"
  when "mysql"
    "SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = '#{W6bQualified::NS}' AND INDEX_NAME = '#{name}'"
  else
    "SELECT COUNT(*) FROM #{W6bQualified::NS}.sqlite_master WHERE type = 'index' AND name = '#{name}'"
  end
end
