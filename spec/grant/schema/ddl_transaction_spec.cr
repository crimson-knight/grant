require "../../support/m03_fixture"

class M03FailsAfterCreate < Grant::Schema::Migration
  migration_version 20240501000001

  def up
    create_table :m03_atomic do |t|
      t.string :label
    end
    raise "boom after create"
  end

  def down
    drop_table :m03_atomic
  end
end

class M03FailsWithoutTransaction < Grant::Schema::Migration
  migration_version 20240501000002
  disable_ddl_transaction!

  def up
    create_table :m03_atomic do |t|
      t.string :label
    end
    raise "boom after create"
  end

  def down
    drop_table :m03_atomic
  end
end

class M03ConcurrentIndex < Grant::Schema::Migration
  migration_version 20240501000003
  disable_ddl_transaction!

  def up
    create_table :m03_users do |t|
      t.string :email
    end
    add_index :m03_users, :email, algorithm: :concurrently
  end

  def down
    drop_table :m03_users
  end
end

class M03ConcurrentIndexInTransaction < Grant::Schema::Migration
  migration_version 20240501000004

  def up
    create_table :m03_users do |t|
      t.string :email
    end
    add_index :m03_users, :email, algorithm: :concurrently
  end
end

class M03RebuildsColumn < Grant::Schema::Migration
  migration_version 20240501000005

  def up
    create_table :m03_users do |t|
      t.string :email
      t.integer :age
    end
    remove_column :m03_users, :age
    add_column :m03_users, :nick, :string
    raise "boom after rebuild" if @fail
  end

  def down
    drop_table :m03_users
  end

  def initialize(@fail = false)
  end
end

describe "DDL transactions" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "rolls a failed migration back with its version when the database has transactional DDL" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03FailsAfterCreate, verbose: false)
    expect_raises(Exception, /boom after create/) { context.migrate }
    if M03Fixture.adapter.supports_ddl_transactions?
      M03Fixture.table?("m03_atomic").should be_false
    else
      M03Fixture.table?("m03_atomic").should be_true
    end
    M03Fixture.versions.should be_empty
  end

  it "leaves the DDL in place when the migration opts out" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03FailsWithoutTransaction, verbose: false)
    expect_raises(Exception, /boom after create/) { context.migrate }
    M03Fixture.table?("m03_atomic").should be_true
    M03Fixture.versions.should be_empty
  end

  it "releases the migration lock after a failure" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03FailsAfterCreate, verbose: false, lock_timeout: 200.milliseconds)
    2.times do
      # MySQL commits DDL as it runs, so the failed run leaves its table behind.
      M03Fixture.adapter.open { |db| db.exec "DROP TABLE IF EXISTS m03_atomic" }
      expect_raises(Exception, /boom after create/) { context.migrate }
    end
  end

  it "builds an index concurrently only outside a transaction" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03ConcurrentIndex, verbose: false)
    context.migrate
    M03Fixture.adapter.schema.indexes("m03_users").map(&.name).should contain "index_m03_users_on_email"
    context.rollback

    inside = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03ConcurrentIndexInTransaction, verbose: false)
    if M03Fixture.adapter.postgres?
      expect_raises(Grant::Schema::InvalidDefinition, /CONCURRENTLY/) { inside.migrate }
    end
  end

  it "runs SQLite table rebuilds inside the migration's transaction" do
    next unless M03Fixture.adapter.sqlite?
    entry = Grant::Schema::MigrationEntry.new(20240501000005_i64, "M03RebuildsColumn", -> { M03RebuildsColumn.new(true).as(Grant::Schema::Migration) })
    context = Grant::Schema::MigrationContext.new(M03Fixture.adapter, [entry], verbose: false)
    expect_raises(Exception, /boom after rebuild/) { context.migrate }
    M03Fixture.table?("m03_users").should be_false
    enforced = M03Fixture.adapter.open { |db| db.scalar("PRAGMA foreign_keys").as(Int).to_i64 }
    enforced.should eq 1

    ok = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03RebuildsColumn, verbose: false)
    ok.migrate
    M03Fixture.column?("m03_users", "nick").should be_true
    M03Fixture.column?("m03_users", "age").should be_false
  end
end
