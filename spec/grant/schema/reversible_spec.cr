require "../../support/m03_fixture"

class M03ReversibleChange < Grant::Schema::Migration
  migration_version 20240301000001

  def change
    create_table :m03_users do |t|
      t.string :email
    end
    add_column :m03_users, :age, :integer
    add_index :m03_users, :email
    rename_column :m03_users, :age, :years
  end
end

class M03ExecuteInChange < Grant::Schema::Migration
  migration_version 20240301000002

  def change
    create_table :m03_posts do |t|
      t.string :title
    end
    execute "UPDATE m03_posts SET title = 'x'"
  end
end

class M03ReversibleBlock < Grant::Schema::Migration
  migration_version 20240301000003

  def change
    create_table :m03_tags do |t|
      t.string :label
    end
    reversible do |direction|
      direction.up { execute "INSERT INTO m03_tags (label) VALUES ('seed')" }
      direction.down { execute "DELETE FROM m03_tags" }
    end
    up_only { execute "INSERT INTO m03_tags (label) VALUES ('second')" }
  end
end

class M03UpWithoutDown < Grant::Schema::Migration
  migration_version 20240301000004

  def up
    create_table :m03_comments do |t|
      t.string :body
    end
  end
end

class M03RevertBlock < Grant::Schema::Migration
  migration_version 20240301000005

  def up
    create_table :m03_revert do |t|
      t.string :label
    end
    execute "CREATE TABLE m03_dry (label VARCHAR(10))"
    revert do
      create_table :m03_dry do |t|
        t.string :label
      end
    end
  end

  def down
    drop_table :m03_revert
  end
end

class M03NothingDefined < Grant::Schema::Migration
  migration_version 20240301000006
end

private def m03_sql_of(dialect : Grant::Schema::Dialect, migration : Grant::Schema::Migration, direction : Symbol) : Array(String)
  recording = Grant::Schema::RecordingStatements.new(dialect)
  migration.attach(recording, M03Fixture.adapter, IO::Memory.new)
  direction == :up ? migration.up : migration.down
  recording.statements
end

describe "reversible migrations" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "records the inverse of each call and replays them in reverse" do
    up = m03_sql_of(Grant::Schema::Dialect::Pg, M03ReversibleChange.new, :up)
    up.first.should start_with "CREATE TABLE \"m03_users\""
    up.any?(&.includes?("ADD COLUMN \"age\"")).should be_true

    down = m03_sql_of(Grant::Schema::Dialect::Pg, M03ReversibleChange.new, :down)
    down[0].should eq "ALTER TABLE \"m03_users\" RENAME COLUMN \"years\" TO \"age\""
    down.any? { |sql| sql.starts_with?("DROP INDEX") && sql.includes?("index_m03_users_on_email") }.should be_true
    down.any?(&.includes?("DROP COLUMN \"age\"")).should be_true
    down.last.should eq "DROP TABLE \"m03_users\""
  end

  it "names the inverse of a recorded command" do
    recorder = Grant::Schema::CommandRecorder.new
    commands = recorder.capture do
      recorder.add_column(:m03_users, :age, :integer)
      recorder.add_index(:m03_users, :age, unique: true)
      recorder.create_table(:m03_a) { |t| t.string :x }
      recorder.rename_table(:m03_a, :m03_b)
      recorder.add_foreign_key(:m03_posts, :m03_users)
      recorder.add_reference(:m03_posts, :user)
      recorder.add_timestamps(:m03_posts)
      recorder.enable_extension(:hstore)
    end
    commands.map(&.name).should eq %w(add_column add_index create_table rename_table add_foreign_key add_reference add_timestamps enable_extension)
    commands.map(&.inverse_name).should eq %w(remove_column remove_index drop_table rename_table remove_foreign_key remove_reference remove_timestamps disable_extension)
    commands.all?(&.reversible?).should be_true
    recorder.commands.should be_empty
  end

  it "raises IrreversibleMigration before anything runs when a step has no inverse" do
    recording = Grant::Schema::RecordingStatements.new(Grant::Schema::Dialect::Pg)
    migration = M03ExecuteInChange.new
    migration.attach(recording, M03Fixture.adapter, IO::Memory.new)
    expect_raises(Grant::Schema::IrreversibleMigration, /execute/) { migration.down }
    recording.statements.should be_empty

    [M03Fixture.adapter].each do |adapter|
      context = Grant::Schema::MigrationContext.for(adapter, M03ExecuteInChange, verbose: false)
      context.migrate
      expect_raises(Grant::Schema::IrreversibleMigration) { context.rollback }
      M03Fixture.table?("m03_posts").should be_true
      M03Fixture.versions.should eq [20240301000002_i64]
    end
  end

  it "gives reversible blocks a direction on each side" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03ReversibleBlock, verbose: false)
    context.migrate
    M03Fixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM m03_tags").as(Int).to_i64 }.should eq 2
    context.rollback
    M03Fixture.table?("m03_tags").should be_false
  end

  it "treats up without down as irreversible" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03UpWithoutDown, verbose: false)
    context.migrate
    expect_raises(Grant::Schema::IrreversibleMigration, /no down/) { context.rollback }
  end

  it "runs a revert block backwards inside up" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03RevertBlock, verbose: false)
    context.migrate
    M03Fixture.table?("m03_revert").should be_true
    M03Fixture.table?("m03_dry").should be_false
  end

  it "rejects a migration that defines nothing" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03NothingDefined, verbose: false)
    expect_raises(Grant::Schema::InvalidMigration, /none of change/) { context.migrate }
  end

  it "migrates and rolls back an automatic change on the real database" do
    context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03ReversibleChange, verbose: false)
    context.migrate
    M03Fixture.column?("m03_users", "years").should be_true
    context.rollback
    M03Fixture.table?("m03_users").should be_false
  end
end
