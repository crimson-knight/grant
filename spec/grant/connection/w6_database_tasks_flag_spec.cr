require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../../src/grant/tasks/database"

private def w6_env(values : Hash(String, String) = {} of String => String) : Proc(String, String?)
  ->(key : String) { values[key]? }
end

private def w6_adapter_key : String
  W6C04.pg? ? "postgres" : "sqlite3"
end

describe "database_tasks: false (#{CURRENT_ADAPTER})" do
  after_all { W6C04.cleanup }

  describe "in a file of named databases" do
    yaml = <<-YAML
      test:
        primary:
          url: #{W6C04.url("tasks_primary")}
        primary_replica:
          url: #{W6C04.url("tasks_primary")}
          replica: true
        reports:
          url: #{W6C04.url("tasks_reports")}
          database_tasks: false
      YAML

    it "leaves replicas and database_tasks: false databases out of the task list" do
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)

      configurations.task_configs.map(&.name).should eq ["primary"]
      configurations.configs_for(env: "test").map(&.name).should eq ["primary", "primary_replica", "reports"]
      Grant::Tasks::Database.for_configurations(configurations).map(&.name).should eq ["primary"]
    end

    it "creates and drops a database whose tasks are enabled" do
      W6C04.drop("tasks_primary")
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)
      tasks = Grant::Tasks::Database.for_config(configurations.db_config("primary"))

      tasks.database_tasks?.should be_true
      tasks.create.should be_true
      tasks.exists?.should be_true
      tasks.drop(force: true).should be_true
      tasks.exists?.should be_false
    end

    it "does nothing for a database whose tasks are disabled" do
      W6C04.drop("tasks_reports")
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)
      tasks = Grant::Tasks::Database.for_config(configurations.db_config("reports"), db_dir: File.join(W6C04.dir, "db_reports"))

      tasks.database_tasks?.should be_false
      tasks.create.should be_false
      tasks.exists?.should be_false

      tasks.migrate.should be_empty
      tasks.rollback.should be_empty
      tasks.seed.should eq 0
      tasks.schema_load.should eq 0
      tasks.truncate_all.should be_empty
      tasks.drop(force: true).should be_false
      tasks.purge(force: true)
      tasks.setup
      tasks.reset(force: true)
      tasks.prepare
      tasks.schema_dump
      tasks.structure_dump
      tasks.exists?.should be_false
      Dir.exists?(File.join(W6C04.dir, "db_reports")).should be_false
    end
  end

  describe "in a file of one database per environment" do
    it "reads the two-tier form as the primary database" do
      yaml = <<-YAML
        test:
          adapter: #{w6_adapter_key}
          url: #{W6C04.url("tasks_single")}
          pool: 7
        production:
          adapter: #{w6_adapter_key}
          url: #{W6C04.url("tasks_single_prod")}
        YAML
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)

      configurations.configs_for(env: "test").map(&.name).should eq ["primary"]
      primary = configurations.db_config("primary")
      primary.url.should eq W6C04.url("tasks_single")
      primary.pool_size.should eq 7
      primary.adapter.should eq W6C04.adapter_class
      configurations.db_config("primary", "production").url.should eq W6C04.url("tasks_single_prod")
    end

    it "honors database_tasks: false in the two-tier form" do
      yaml = <<-YAML
        test:
          adapter: #{w6_adapter_key}
          url: #{W6C04.url("tasks_single_off")}
          database_tasks: false
        YAML
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)

      configurations.db_config("primary").database_tasks?.should be_false
      configurations.task_configs.should be_empty
      Grant::Tasks::Database.for_configurations(configurations).should be_empty
    end

    it "applies DATABASE_URL to the single database" do
      yaml = <<-YAML
        test:
          adapter: #{w6_adapter_key}
          url: #{W6C04.url("tasks_single")}
        YAML
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env({"DATABASE_URL" => W6C04.url("tasks_from_env")}))

      configurations.db_config("primary").url.should eq W6C04.url("tasks_from_env")
    end

    it "reads a SQLite file named by database:" do
      yaml = <<-YAML
        test:
          adapter: sqlite3
          database: ./db/test.sqlite3
        YAML
      configurations = Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)

      configurations.db_config("primary").url.should eq "sqlite3:./db/test.sqlite3"
    end

    it "runs the tasks of the single database" do
      W6C04.drop("tasks_single_run")
      yaml = <<-YAML
        test:
          adapter: #{w6_adapter_key}
          url: #{W6C04.url("tasks_single_run")}
        YAML
      tasks = Grant::Tasks::Database.for_configurations(Grant::DatabaseConfigurations.parse(yaml, "test", w6_env)).first

      tasks.create.should be_true
      tasks.exists?.should be_true
      tasks.drop(force: true).should be_true
    end

    it "still rejects a file that is not a mapping of environments" do
      expect_raises(Grant::DatabaseConfigurationError) { Grant::DatabaseConfigurations.parse("- one\n- two\n", "test", w6_env) }
      expect_raises(Grant::DatabaseConfigurationError) { Grant::DatabaseConfigurations.parse("test: nope\n", "test", w6_env) }
    end
  end
end
