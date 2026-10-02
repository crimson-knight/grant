require "../../support/m04_tasks_fixture"

private def m04_options
  {migrations: M04_TASK_MIGRATIONS, db_dir: "db_m04", seed_path: "db_m04/seeds.cr"}
end

describe Grant::Tasks::Database do
  describe "named connections" do
    it "runs on the registered connection's adapter and URL" do
      tasks = Grant::Tasks::Database.for_connection("development", CURRENT_ADAPTER, **m04_options)
      tasks.adapter.should be Grant::ConnectionRegistry.get_adapter(CURRENT_ADAPTER)
      tasks.url.should start_with(ADAPTER_URL)
      tasks.name.should eq CURRENT_ADAPTER
      tasks.exists?.should be_true
      tasks.version.should be >= 0
      expect_raises(Grant::Schema::ProtectedEnvironmentError) { Grant::Tasks::Database.for_connection("production", CURRENT_ADAPTER, **m04_options).drop }
    end

    it "builds from a database configuration entry" do
      config = Grant::DatabaseConfig.new("analytics", "staging", CURRENT_ADAPTER == "pg" ? "postgres" : "sqlite3", M04Tasks.url("m04_config"))
      tasks = Grant::Tasks::Database.for_config(config, **m04_options)
      tasks.environment.should eq "staging"
      tasks.name.should eq "analytics"
      tasks.schema_path.should eq "db_m04/analytics_schema.cr"
      tasks.exists?.should be_false
    end
  end

  describe "#create, #exists? and #drop" do
    it "creates a missing database once and drops it" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.exists?.should be_false
        tasks.create.should be_true
        tasks.exists?.should be_true
        tasks.create.should be_false
        tasks.adapter.open { |db| db.scalar("SELECT 1").as(Int).to_i64 }.should eq 1

        tasks.drop.should be_true
        tasks.exists?.should be_false
        tasks.drop.should be_false
      end
    end
  end

  describe "production guard" do
    it "refuses to drop, purge, reset or schema_load in a protected environment" do
      M04Tasks.with_tasks("production", **m04_options) do |tasks|
        tasks.create
        expect_raises(Grant::Schema::ProtectedEnvironmentError, /production/) { tasks.drop }
        expect_raises(Grant::Schema::ProtectedEnvironmentError) { tasks.purge }
        expect_raises(Grant::Schema::ProtectedEnvironmentError) { tasks.reset }
        expect_raises(Grant::Schema::ProtectedEnvironmentError) { tasks.schema_load }
        tasks.exists?.should be_true

        tasks.drop(force: true).should be_true
        tasks.exists?.should be_false
      end
    end

    it "guards before it connects, so an unreachable production database is not touched" do
      tasks = M04Tasks.tasks(M04Tasks.unique_name, "production")
      expect_raises(Grant::Schema::ProtectedEnvironmentError) { tasks.drop }
    end

    it "refuses a database recorded as production from another environment" do
      name = M04Tasks.unique_name
      production = M04Tasks.tasks(name, "production", **m04_options)
      begin
        production.create
        production.migrate
        production.adapter.schema.table_exists?("ar_internal_metadata").should be_true

        development = M04Tasks.tasks(name, "development", **m04_options)
        expect_raises(Grant::Schema::ProtectedEnvironmentError) { development.drop }
        expect_raises(Grant::Schema::ProtectedEnvironmentError) { development.truncate_all }
        development.drop(force: true).should be_true
      ensure
        production.drop(force: true)
      end
    end

    it "refuses a database that belongs to another environment" do
      name = M04Tasks.unique_name
      development = M04Tasks.tasks(name, "development", **m04_options)
      begin
        development.create
        development.migrate
        testing = M04Tasks.tasks(name, "test", **m04_options)
        expect_raises(Grant::Schema::EnvironmentMismatchError) { testing.drop }
      ensure
        development.drop(force: true)
      end
    end

    it "honors a custom list of protected environments" do
      M04Tasks.with_tasks("staging", **m04_options, protected_environments: ["staging"]) do |tasks|
        tasks.create
        expect_raises(Grant::Schema::ProtectedEnvironmentError, /staging/) { tasks.drop }
      end
    end
  end

  describe "#purge" do
    it "leaves an empty database in place" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.create
        tasks.adapter.open { |db| db.exec "CREATE TABLE m04_purge_me (id INTEGER)" }
        M04Tasks.table?(tasks, "m04_purge_me").should be_true

        tasks.purge
        tasks.exists?.should be_true
        M04Tasks.table?(tasks, "m04_purge_me").should be_false
      end
    end
  end

  describe "migrations" do
    it "migrates, reports status and version, and rolls back" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.create
        tasks.version.should eq 0
        tasks.migrate.should eq [20260101000001_i64, 20260101000002_i64, 20260101000003_i64]
        tasks.version.should eq 20260101000003_i64
        tasks.status.map(&.state).should eq ["up", "up", "up"]
        M04Tasks.table?(tasks, "m04_task_gadgets").should be_true

        tasks.rollback.should eq [20260101000003_i64]
        tasks.status.map(&.state).should eq ["up", "up", "down"]
        tasks.migrate.should eq [20260101000003_i64]
      end
    end

    it "writes the schema file after migrating when asked" do
      dir = File.join(Dir.tempdir, "m04_dump_#{Random::Secure.hex(4)}")
      begin
        M04Tasks.with_tasks(**m04_options.merge(db_dir: dir)) do |tasks|
          tasks.create
          tasks.migrate(dump: true)
          text = File.read(File.join(dir, "schema.cr"))
          text.should contain("m04_task_widgets")
          text.should contain("m04_task_gadgets")
          text.should contain("Grant::Schema.define(version: 20260101000003)")
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#setup" do
    it "creates the database, loads the schema, records its versions and seeds" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.setup
        M04Tasks.table?(tasks, "m04_task_gadgets").should be_true
        tasks.version.should eq 20260101000002_i64
        Grant::Schema::SchemaMigration.new(tasks.adapter).versions.to_a.sort.should eq [20260101000001_i64, 20260101000002_i64]
        tasks.migration_context.pending.map(&.version).should eq [20260101000003_i64]
        M04Tasks.count(tasks, "m04_task_widgets").should eq 1
        Grant::Seeds.applied(tasks.adapter).should eq ["m04-widget"]
      end
    end
  end

  describe "#reset" do
    it "drops and sets the database up again" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.setup
        tasks.adapter.open { |db| db.exec "INSERT INTO m04_task_widgets (title) VALUES ('extra')" }
        M04Tasks.count(tasks, "m04_task_widgets").should eq 2

        tasks.reset
        M04Tasks.count(tasks, "m04_task_widgets").should eq 1
        tasks.version.should eq 20260101000002_i64
      end
    end

    it "skips the seeds when asked" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.setup
        tasks.reset(seed: false)
        M04Tasks.count(tasks, "m04_task_widgets").should eq 0
      end
    end
  end

  describe "#prepare" do
    it "sets up a new database: schema, pending migrations are left alone, seeds run" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.exists?.should be_false
        tasks.prepare
        tasks.exists?.should be_true
        M04Tasks.table?(tasks, "m04_task_widgets").should be_true
        M04Tasks.count(tasks, "m04_task_widgets").should eq 1
        tasks.version.should eq 20260101000002_i64
      end
    end

    it "migrates an existing database and never seeds or reloads it" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.prepare
        tasks.adapter.open(&.exec("DELETE FROM m04_task_widgets"))

        tasks.prepare
        tasks.version.should eq 20260101000003_i64
        M04Tasks.count(tasks, "m04_task_widgets").should eq 0
        tasks.adapter.reset_schema_caches!
        tasks.adapter.schema.column_exists?(:m04_task_gadgets, :color).should be_true
      end
    end

    it "runs the migrations of a new database that has no schema file" do
      M04Tasks.with_tasks(**m04_options.merge(db_dir: "db_m04_absent", seed_path: "db_m04_absent/seeds.cr")) do |tasks|
        tasks.prepare
        tasks.version.should eq 20260101000003_i64
        M04Tasks.table?(tasks, "m04_task_gadgets").should be_true
      end
    end

    it "does nothing twice" do
      M04Tasks.with_tasks(**m04_options) do |tasks|
        tasks.prepare
        tasks.prepare
        tasks.prepare
        tasks.version.should eq 20260101000003_i64
        M04Tasks.count(tasks, "m04_task_widgets").should eq 1
      end
    end
  end

  describe "schema format" do
    it "defaults to Crystal and accepts :sql" do
      Grant::Schema.format.should eq Grant::Schema::SchemaFormat::Crystal
      Grant::Schema.format = :sql
      begin
        M04Tasks.tasks("x", **m04_options).schema_path.should eq "db_m04/structure.sql"
      ensure
        Grant::Schema.format = :crystal
      end
      M04Tasks.tasks("x", **m04_options).schema_path.should eq "db_m04/schema.cr"
      Grant::Tasks::Database.new(M04Tasks.url("x"), "development", "analytics", **m04_options).schema_path.should eq "db_m04/analytics_schema.cr"
      expect_raises(Grant::Schema::InvalidDefinition) { Grant::Schema.format = :yaml }
    end

    it "dumps and loads the SQL structure" do
      next if CURRENT_ADAPTER == "pg" && (Process.find_executable("pg_dump").nil? || Process.find_executable("psql").nil?)
      source = M04Tasks.tasks(M04Tasks.unique_name, **m04_options)
      copy = M04Tasks.tasks(M04Tasks.unique_name, **m04_options.merge(schema_format: Grant::Schema::SchemaFormat::Sql))
      path = File.join(Dir.tempdir, "m04_structure_#{Random::Secure.hex(4)}.sql")
      begin
        source.create
        source.migrate
        source.adapter.open { |db| db.exec "INSERT INTO m04_task_widgets (title) VALUES ('row')" }
        source.structure_dump(path)
        File.read(path).should contain("m04_task_gadgets")
        File.read(path).should contain("20260101000003")

        copy.create
        copy.schema_load(path).should eq 20260101000003_i64
        M04Tasks.table?(copy, "m04_task_widgets").should be_true
        M04Tasks.count(copy, "m04_task_widgets").should eq 0
        copy.adapter.schema.column_exists?(:m04_task_gadgets, :color).should be_true
        copy.version.should eq 20260101000003_i64
        copy.migration_context.pending.should be_empty
      ensure
        File.delete?(path)
        source.drop(force: true)
        copy.drop(force: true)
      end
    end
  end
end
