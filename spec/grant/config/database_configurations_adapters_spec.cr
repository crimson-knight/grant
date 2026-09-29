require "../../spec_helper"

def c03_adapters_env(values : Hash(String, String)) : Proc(String, String?)
  ->(key : String) { values[key]? }
end

describe "Grant::DatabaseConfigurations adapter resolution" do
  it "loads a file whose other environments name an adapter this build never required" do
    yaml = <<-YAML
      test:
        primary:
          url: "sqlite3::memory:"
      production:
        primary:
          url: oracle://prod/app
      YAML
    configs = Grant::DatabaseConfigurations.parse(yaml, "test", c03_adapters_env({} of String => String))

    configs.db_config("primary").adapter.should eq Grant::Adapter::Sqlite
    production = configs.db_config("primary", "production")
    production.adapter_name.should eq "oracle"
    production.adapter?.should be_nil
    expect_raises(Grant::UnknownAdapterError) { production.adapter }
  end

  it "still rejects an unknown adapter in the current environment" do
    expect_raises(Grant::UnknownAdapterError) do
      Grant::DatabaseConfigurations.parse("test:\n  primary:\n    adapter: oracle\n    url: x.db\n", "test",
        c03_adapters_env({} of String => String))
    end
  end

  it "lets the DATABASE_URL scheme replace the file's adapter key" do
    yaml = "production:\n  primary:\n    adapter: sqlite\n    url: file.db\n    pool: 4\n"
    env = c03_adapters_env({"DATABASE_URL" => "postgres://override/app"})
    primary = Grant::DatabaseConfigurations.parse(yaml, "production", env).db_config("primary")

    primary.adapter.should eq Grant::Adapter::Pg
    primary.pool_size.should eq 4
  end

  it "keeps the file's adapter key when the override URL has no scheme" do
    yaml = "production:\n  primary:\n    adapter: sqlite\n    url: file.db\n"
    env = c03_adapters_env({"DATABASE_URL" => "other.db"})
    primary = Grant::DatabaseConfigurations.parse(yaml, "production", env).db_config("primary")

    primary.url.should eq "other.db"
    primary.adapter.should eq Grant::Adapter::Sqlite
  end

  it "redacts passwords that contain a slash or an at sign" do
    Grant::Adapter::Registry.redact("postgres://user:pa/ss@host/db").should eq "postgres://***@host/db"
    Grant::Adapter::Registry.redact("postgres://user:p@ss@host/db?x=1").should eq "postgres://***@host/db?x=1"
    Grant::Adapter::Registry.redact("postgres://host/db").should eq "postgres://host/db"
  end
end
