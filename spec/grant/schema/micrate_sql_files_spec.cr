require "../../support/m03_fixture"

private def m03_write(dir : String, file : String, text : String) : Nil
  File.write(File.join(dir, file), text)
end

private def m03_micrate_seed(adapter : Grant::Adapter::Base, rows : Array({Int64, Bool})) : Nil
  # An install Micrate itself created: its table, its seed row, its history.
  Grant::Schema::SchemaMigration.new(adapter, Grant::Schema::Tracking::Micrate).create_table
  truthy = adapter.sqlite? ? {"1", "0"} : {"true", "false"}
  ([{0_i64, true}] + rows).each do |version, applied|
    adapter.open { |db| db.exec "INSERT INTO micrate_db_version (version_id, is_applied) VALUES (#{version}, #{applied ? truthy[0] : truthy[1]})" }
  end
end

describe "Micrate SQL migration files" do
  before_each { M03Fixture.reset! }
  after_all { M03Fixture.reset! }

  it "parses Up and Down sections, multi-line statements and StatementBegin blocks" do
    text = <<-SQL
      -- a leading comment
      -- +micrate Up
      -- +micrate StatementBegin
      CREATE TABLE m03_sql_one (
        id INTEGER PRIMARY KEY,
        note VARCHAR(20)
      );
      -- +micrate StatementEnd
      INSERT INTO m03_sql_one (id, note) VALUES (1, 'a;b');

      -- +micrate Down
      DROP TABLE m03_sql_one;
      SQL
    migration = Grant::Schema::SqlFileMigration.parse(1_i64, "Create", text)
    migration.up_statements.size.should eq 2
    migration.up_statements[0].should start_with "CREATE TABLE m03_sql_one ("
    migration.up_statements[0].should contain "note VARCHAR(20)\n);"
    migration.up_statements[1].should eq "INSERT INTO m03_sql_one (id, note) VALUES (1, 'a;b');"
    migration.down_statements.should eq ["DROP TABLE m03_sql_one;"]
    migration.no_transaction?.should be_false

    Grant::Schema::SqlFileMigration.parse(2_i64, "X", "-- +micrate Up\n-- +micrate NoTransaction\nSELECT 1;\n").no_transaction?.should be_true
  end

  it "rejects malformed files" do
    expect_raises(Grant::Schema::InvalidMigration, /before the -- \+micrate Up/) do
      Grant::Schema::SqlFileMigration.parse(1_i64, "Bad", "CREATE TABLE x (a INT);\n-- +micrate Up\n")
    end
    expect_raises(Grant::Schema::InvalidMigration, /unterminated/) do
      Grant::Schema::SqlFileMigration.parse(1_i64, "Bad", "-- +micrate Up\n-- +micrate StatementBegin\nSELECT 1;\n")
    end
    expect_raises(Grant::Schema::InvalidMigration, /semicolon/) do
      Grant::Schema::SqlFileMigration.parse(1_i64, "Bad", "-- +micrate Up\nSELECT 1\n")
    end
  end

  it "migrates and rolls back files from a directory" do
    M03Fixture.tmpdir do |dir|
      m03_write(dir, "20240401000001_create_sql_one.sql", "-- +micrate Up\nCREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_one;\n")
      m03_write(dir, "20240401000002_create_sql_two.sql", "-- +micrate Up\nCREATE TABLE m03_sql_two (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_two;\n")
      m03_write(dir, "notes.txt", "ignored")
      context = Grant::Schema::MigrationContext.new(M03Fixture.adapter, paths: [dir], verbose: false)
      context.migrations.map(&.name).should eq ["CreateSqlOne", "CreateSqlTwo"]
      context.migrate.should eq [20240401000001_i64, 20240401000002_i64]
      M03Fixture.table?("m03_sql_two").should be_true
      M03Fixture.versions.should eq [20240401000001_i64, 20240401000002_i64]
      context.rollback
      M03Fixture.table?("m03_sql_two").should be_false
      M03Fixture.table?("m03_sql_one").should be_true
    end
  end

  it "mixes Crystal classes and SQL files in one version order" do
    M03Fixture.tmpdir do |dir|
      m03_write(dir, "20240401000005_create_sql_one.sql", "-- +micrate Up\nCREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_one;\n")
      context = Grant::Schema::MigrationContext.for(M03Fixture.adapter, M03CreatePosts, paths: [dir], verbose: false)
      context.migrations.map(&.version).should eq [20240101000003_i64, 20240401000005_i64]
      context.migrate.size.should eq 2
    end
  end

  it "refuses a file without a Down section when rolling back" do
    M03Fixture.tmpdir do |dir|
      m03_write(dir, "20240401000001_create_sql_one.sql", "-- +micrate Up\nCREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY);\n")
      context = Grant::Schema::MigrationContext.new(M03Fixture.adapter, paths: [dir], verbose: false)
      context.migrate
      expect_raises(Grant::Schema::IrreversibleMigration, /Down/) { context.rollback }
    end
  end

  it "keeps working on top of an existing Micrate install's table" do
    M03Fixture.tmpdir do |dir|
      m03_write(dir, "20240401000001_create_sql_one.sql", "-- +micrate Up\nCREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_one;\n")
      m03_write(dir, "20240401000002_create_sql_two.sql", "-- +micrate Up\nCREATE TABLE m03_sql_two (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_two;\n")
      # Micrate already ran version 1 (and once ran, then reverted, version 2).
      M03Fixture.adapter.open { |db| db.exec "CREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY)" }
      m03_micrate_seed(M03Fixture.adapter, [{20240401000001_i64, true}, {20240401000002_i64, true}, {20240401000002_i64, false}])

      context = Grant::Schema::MigrationContext.new(M03Fixture.adapter, paths: [dir], tracking: Grant::Schema::Tracking::Micrate, verbose: false)
      context.applied_versions.should eq Set{20240401000001_i64}
      context.pending.map(&.version).should eq [20240401000002_i64]
      context.migrate.should eq [20240401000002_i64]
      M03Fixture.versions(tracking: Grant::Schema::Tracking::Micrate).should eq [20240401000001_i64, 20240401000002_i64]
      M03Fixture.table?("schema_migrations").should be_false

      context.rollback
      M03Fixture.versions(tracking: Grant::Schema::Tracking::Micrate).should eq [20240401000001_i64]
      # Micrate's own way of recording a revert: a new row with is_applied false.
      rows = M03Fixture.adapter.open { |db| db.scalar("SELECT COUNT(*) FROM micrate_db_version WHERE version_id = 20240401000002").as(Int).to_i64 }
      rows.should eq 4
    end
  end

  it "creates the Micrate table when there is none" do
    M03Fixture.tmpdir do |dir|
      m03_write(dir, "20240401000001_create_sql_one.sql", "-- +micrate Up\nCREATE TABLE m03_sql_one (id INTEGER PRIMARY KEY);\n-- +micrate Down\nDROP TABLE m03_sql_one;\n")
      context = Grant::Schema::MigrationContext.new(M03Fixture.adapter, paths: [dir], tracking: Grant::Schema::Tracking::Micrate, verbose: false)
      context.migrate
      M03Fixture.table?("micrate_db_version").should be_true
      context.current_version.should eq 20240401000001_i64
    end
  end
end
