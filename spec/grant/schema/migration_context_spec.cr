require "../../support/m03_fixture"

describe Grant::Schema::MigrationContext do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "migrates everything pending, in version order, and tracks it" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreatePosts, M03AddAgeToUsers, M03CreateUsers, verbose: false)
    context.pending.map(&.version).should eq [20240101000001_i64, 20240101000002_i64, 20240101000003_i64]
    context.migrate.should eq [20240101000001_i64, 20240101000002_i64, 20240101000003_i64]
    M03Fixture.table?("m03_users").should be_true
    M03Fixture.column?("m03_users", "age").should be_true
    M03Fixture.table?("m03_posts").should be_true
    M03Fixture.versions.should eq [20240101000001_i64, 20240101000002_i64, 20240101000003_i64]
    context.current_version.should eq 20240101000003_i64
    context.migrate.should be_empty
  end

  it "migrates up and down to a version" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, M03CreatePosts, verbose: false)
    context.migrate(20240101000002_i64).should eq [20240101000001_i64, 20240101000002_i64]
    M03Fixture.table?("m03_posts").should be_false
    context.migrate(20240101000003_i64).should eq [20240101000003_i64]
    context.migrate(20240101000001_i64).should eq [20240101000003_i64, 20240101000002_i64]
    M03Fixture.column?("m03_users", "age").should be_false
    M03Fixture.table?("m03_users").should be_true
    context.migrate(0_i64).should eq [20240101000001_i64]
    M03Fixture.table?("m03_users").should be_false
    M03Fixture.versions.should be_empty
    expect_raises(Grant::Schema::UnknownMigrationVersion) { context.migrate(42_i64) }
  end

  it "rolls back by step, redoes, and moves forward" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, M03CreatePosts, verbose: false)
    context.migrate
    context.rollback.should eq [20240101000003_i64]
    M03Fixture.table?("m03_posts").should be_false
    context.rollback(2).should eq [20240101000002_i64, 20240101000001_i64]
    M03Fixture.table?("m03_users").should be_false

    context.forward.should eq [20240101000001_i64]
    context.forward(2).should eq [20240101000002_i64, 20240101000003_i64]
    context.forward.should be_empty

    context.redo(2).should eq [20240101000003_i64, 20240101000002_i64, 20240101000002_i64, 20240101000003_i64]
    M03Fixture.versions.size.should eq 3
    M03Fixture.column?("m03_users", "age").should be_true
  end

  it "runs and reverses one version with up and down, skipping what already happened" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, verbose: false)
    context.up(20240101000002_i64).should eq [20240101000002_i64] if context.up(20240101000001_i64) == [20240101000001_i64]
    context.up(20240101000002_i64).should be_empty
    M03Fixture.column?("m03_users", "age").should be_true
    context.down(20240101000002_i64).should eq [20240101000002_i64]
    context.down(20240101000002_i64).should be_empty
    M03Fixture.column?("m03_users", "age").should be_false
    expect_raises(Grant::Schema::UnknownMigrationVersion) { context.up(1_i64) }
  end

  it "reports status, including a recorded version that has no file" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, verbose: false)
    context.forward
    Grant::Schema::SchemaMigration.new(M03Fixture.adapter).record(20200101000000_i64)
    rows = context.status
    rows.map(&.version).should eq [20200101000000_i64, 20240101000001_i64, 20240101000002_i64]
    rows.map(&.state).should eq ["up", "up", "down"]
    rows[0].missing?.should be_true
    rows[0].name.should eq Grant::Schema::MigrationStatus::NO_FILE
    rows[1].name.should eq "M03CreateUsers"
    rows[2].to_s.should eq "down  20240101000002  M03AddAgeToUsers"
  end

  it "reads the applied versions with one SELECT however many migrations there are" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03AddAgeToUsers, M03CreatePosts, verbose: false)
    context.migrate
    queries = [] of String
    handler = ->(event : Grant::Events::SQL) { queries << event.sql; nil }
    Grant::Notifications.subscribed(Grant::Events::SQL, handler) do
      context.pending.should be_empty
    end
    queries.count(&.includes?("schema_migrations")).should eq 1
  end

  it "announces each migration and the schema calls it makes" do
    io = IO::Memory.new
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, output: io)
    context.migrate
    text = io.to_s
    text.should contain "== M03CreateUsers: migrating"
    text.should contain "-- create_table(:m03_users)"
    text.should match /-> \d+\.\d{4}s/
    text.should contain "== M03CreateUsers: migrated ("
    io.clear
    context.rollback
    io.to_s.should contain "== M03CreateUsers: reverting"
    io.to_s.should contain "-- drop_table"
  end

  it "prints the SQL of a dry run and changes nothing" do
    io = IO::Memory.new
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, output: io, dry_run: true)
    context.migrate.should eq [20240101000001_i64]
    io.to_s.should contain "CREATE TABLE"
    M03Fixture.table?("m03_users").should be_false
    M03Fixture.table?("schema_migrations").should be_false
  end

  it "prints say, say_with_time and announce output and silences it with suppress_messages" do
    io = IO::Memory.new
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03Chatty, output: io)
    context.migrate
    text = io.to_s
    text.should contain "-- hello from the migration"
    text.should contain "-- backfill"
    text.should contain "   -> 3 rows"
    text.should contain "== M03Chatty: announced ="
    text.should_not contain "hidden"
  end

  it "runs a migration once when two runners start together" do
    M03SlowOnce.runs = 0
    done = Channel(Nil).new
    2.times do
      spawn do
        Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03SlowOnce, verbose: false).migrate
        done.send(nil)
      end
    end
    2.times { done.receive }
    M03SlowOnce.runs.should eq 1
    M03Fixture.versions.should eq [20240201000003_i64]
  end

  it "rejects two migrations with the same version" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreateUsers, M03CreateUsers, verbose: false)
    expect_raises(Grant::Schema::InvalidMigration, /same|Two migrations/) { context.migrate }
  end

  it "runs a raw execute and qualified table names through the runner" do
    qualified = M03Fixture.adapter.postgres? ? "public.m03_widgets" : "m03_widgets"
    klass = M03Fixture.adapter.postgres? ? M03QualifiedPg : M03RawExecute
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, klass, verbose: false)
    context.migrate
    M03Fixture.table?("m03_widgets").should be_true
    count = M03Fixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM #{qualified}").as(Int).to_i64 }
    count.should eq 1
    context.rollback
    M03Fixture.table?("m03_widgets").should be_false
  end
end

class M03RawExecute < Grant::Schema::Migration
  migration_version 20240201000001

  def up
    create_table :m03_widgets do |t|
      t.string :label
    end
    execute "INSERT INTO m03_widgets (label) VALUES ('first')"
  end

  def down
    drop_table :m03_widgets
  end
end

class M03QualifiedPg < Grant::Schema::Migration
  migration_version 20240201000002

  def up
    create_table "public.m03_widgets" do |t|
      t.string :label
    end
    add_index "public.m03_widgets", :label
    add_column "public.m03_widgets", :note, :string
    execute "INSERT INTO public.m03_widgets (label) VALUES ('first')"
  end

  def down
    drop_table "public.m03_widgets"
  end
end

class M03Chatty < Grant::Schema::Migration
  migration_version 20240201000004

  def up
    say "hello from the migration"
    say_with_time("backfill") { 3 }
    announce "announced"
    suppress_messages { say "hidden" }
  end

  def down
  end
end

class M03SlowOnce < Grant::Schema::Migration
  migration_version 20240201000003

  class_property runs = 0

  def up
    self.class.runs += 1
    sleep 100.milliseconds
  end

  def down
  end
end
