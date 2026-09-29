require "../../spec_helper"

C03_CONFIG_YAML = <<-YAML
  development:
    primary:
      url: sqlite3:./dev.db
  production:
    primary:
      url: postgres://prod-writer/app
      pool: 10
    primary_replica:
      url: postgres://prod-reader/app
      replica: true
    reports:
      url: mysql://prod-reports/reports
      database_tasks: false
    legacy:
      adapter: sqlite
      url: file-legacy.db
  YAML

def c03_env(values : Hash(String, String)) : Proc(String, String?)
  ->(key : String) { values[key]? }
end

describe Grant::DatabaseConfigurations do
  it "lists every configuration of an environment with typed values" do
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", c03_env({} of String => String))
    production = configs.configs_for(env: "production")

    production.map(&.name).should eq ["primary", "primary_replica", "reports", "legacy"]
    primary = production.first
    primary.adapter.should eq Grant::Adapter::Pg
    primary.pool_size.should eq 10
    primary.replica?.should be_false
    primary.database_tasks?.should be_true
    primary.role.should eq :writing
    primary.scheme.should eq "postgres"
  end

  it "marks replicas, attaches them to their database, and tracks database_tasks" do
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", c03_env({} of String => String))

    replica = configs.db_config("primary_replica")
    replica.replica?.should be_true
    replica.database.should eq "primary"
    replica.role.should eq :reading
    configs.configs_for(env: "production", include_replicas: false).map(&.name).should eq ["primary", "reports", "legacy"]
    configs.db_config("reports").database_tasks?.should be_false
    configs.db_config("reports").adapter.should eq Grant::Adapter::Mysql
    configs.config_for_database("primary", replica: true).try(&.url).should eq "postgres://prod-reader/app"
  end

  it "filters by environment and name" do
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", c03_env({} of String => String))

    configs.configs_for(env: "development").map(&.url).should eq ["sqlite3:./dev.db"]
    configs.configs_for(name: "primary").map(&.env).should eq ["development", "production"]
    configs.configs_for(env: "production", name: "reports").size.should eq 1
    configs.configs_for(env: "staging").should be_empty
    configs.find_db_config("missing").should be_nil
    expect_raises(Grant::DatabaseConfigurationError, /missing/) { configs.db_config("missing") }
  end

  it "lets DATABASE_URL replace the primary url of the current environment only" do
    env = c03_env({"DATABASE_URL" => "postgres://override/app"})
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", env)

    primary = configs.db_config("primary")
    primary.url.should eq "postgres://override/app"
    primary.pool_size.should eq 10 # other keys survive the merge
    configs.db_config("primary", "development").url.should eq "sqlite3:./dev.db"
    configs.db_config("reports").url.should eq "mysql://prod-reports/reports"
  end

  it "lets a per-name <NAME>_DATABASE_URL win over DATABASE_URL for that name" do
    env = c03_env({
      "DATABASE_URL"         => "postgres://generic/app",
      "PRIMARY_DATABASE_URL" => "postgres://specific/app",
      "REPORTS_DATABASE_URL" => "postgres://reports-override/reports",
    })
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", env)

    configs.db_config("primary").url.should eq "postgres://specific/app"
    configs.db_config("reports").url.should eq "postgres://reports-override/reports"
    configs.db_config("reports").adapter.should eq Grant::Adapter::Pg # inferred from the new scheme
    configs.db_config("reports").database_tasks?.should be_false
    configs.db_config("primary_replica").url.should eq "postgres://prod-reader/app"
  end

  it "builds the primary from DATABASE_URL when the environment is not in the file" do
    env = c03_env({"DATABASE_URL" => "mysql://only-env/app"})
    configs = Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "staging", env)

    configs.configs_for(env: "staging").map { |config| {config.name, config.adapter} }
      .should eq [{"primary", Grant::Adapter::Mysql}]
  end

  it "ignores an empty override" do
    env = c03_env({"DATABASE_URL" => ""})
    Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", env).db_config("primary").url
      .should eq "postgres://prod-writer/app"
  end

  it "takes an explicit adapter key over the URL scheme" do
    Grant::DatabaseConfigurations.parse(C03_CONFIG_YAML, "production", c03_env({} of String => String))
      .db_config("legacy").adapter.should eq Grant::Adapter::Sqlite
  end

  it "reports a missing url, an unknown adapter, and malformed YAML" do
    expect_raises(Grant::DatabaseConfigurationError, /no url/) do
      Grant::DatabaseConfigurations.parse("test:\n  primary:\n    pool: 3\n", "test", c03_env({} of String => String))
    end
    expect_raises(Grant::UnknownAdapterError) do
      Grant::DatabaseConfigurations.parse("test:\n  primary:\n    url: oracle://h/d\n", "test", c03_env({} of String => String))
    end
    expect_raises(Grant::DatabaseConfigurationError, /Invalid database configuration/) do
      Grant::DatabaseConfigurations.parse("test: [unclosed", "test", c03_env({} of String => String))
    end
  end

  it "loads from a file path" do
    path = File.join(Dir.tempdir, "c03_database_#{Process.pid}.yml")
    File.write(path, C03_CONFIG_YAML)
    begin
      Grant::DatabaseConfigurations.load(path, "development", c03_env({} of String => String))
        .db_config("primary").adapter.should eq Grant::Adapter::Sqlite
    ensure
      File.delete?(path)
    end
  end

  it "never prints credentials in redacted_url" do
    config = Grant::DatabaseConfigurations.parse("test:\n  primary:\n    url: postgres://user:hunter2@h/d\n", "test", c03_env({} of String => String)).db_config("primary")
    config.redacted_url.should_not contain "hunter2"
  end

  describe "establishing connections" do
    it "registers primaries as writing and replicas as reading, and exposes the model's db_config" do
      yaml = <<-YAML
        test:
          c03cfg_db:
            url: "sqlite3::memory:"
          c03cfg_db_replica:
            url: "sqlite3::memory:"
            replica: true
        YAML
      previous = Grant.configurations?
      configs = Grant::DatabaseConfigurations.parse(yaml, "test", c03_env({} of String => String))
      begin
        configs.establish_connections.size.should eq 2
        Grant::ConnectionRegistry.connection_exists?("c03cfg_db", :writing).should be_true
        Grant::ConnectionRegistry.connection_exists?("c03cfg_db", :reading).should be_true

        Grant.configurations = configs
        C03ConfigModel.connected_to(role: :writing) { C03ConfigModel.connection_db_config.name }.should eq "c03cfg_db"
        C03ConfigModel.connected_to(role: :reading) { C03ConfigModel.connection_db_config }.replica?.should be_true
      ensure
        Grant.configurations = previous
        Grant::ConnectionRegistry.remove_connection("c03cfg_db", :writing)
        Grant::ConnectionRegistry.remove_connection("c03cfg_db", :reading)
      end
    end
  end
end

class C03ConfigModel < Grant::Base
  connects_to database: "c03cfg_db"
  table c03_config_models
  column id : Int64, primary: true
end
