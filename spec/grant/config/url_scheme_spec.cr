require "../../spec_helper"

describe "adapter inference from the URL scheme" do
  it "chooses the adapter from postgres://, mysql:// and sqlite3:" do
    Grant::Adapter::Registry.for_url("postgres://u:p@host/db").should eq Grant::Adapter::Pg
    Grant::Adapter::Registry.for_url("postgresql://host/db").should eq Grant::Adapter::Pg
    Grant::Adapter::Registry.for_url("mysql://host/db").should eq Grant::Adapter::Mysql
    Grant::Adapter::Registry.for_url("sqlite3:./app.db").should eq Grant::Adapter::Sqlite
    Grant::Adapter::Registry.for_url("sqlite3://./app.db").should eq Grant::Adapter::Sqlite
  end

  it "exposes the lookup as Grant.adapter_for_scheme" do
    Grant.adapter_for_scheme("postgres").should eq Grant::Adapter::Pg
    Grant.adapter_for_scheme("SQLITE3").should eq Grant::Adapter::Sqlite
  end

  it "raises an actionable error for an unknown scheme without leaking credentials" do
    error = expect_raises(Grant::UnknownAdapterError, /oracle/) do
      Grant::Adapter::Registry.for_url("oracle://user:hunter2@host/db")
    end
    error.message.to_s.should contain "require"
    error.message.to_s.should_not contain "hunter2"
  end

  it "raises for a URL without a scheme" do
    expect_raises(Grant::UnknownAdapterError, /no URL scheme/) do
      Grant::Adapter::Registry.for_url("just-a-path.db")
    end
  end

  it "supports registering a custom adapter by name" do
    Grant::Adapter::Registry.register(Grant::Adapter::Sqlite, "c03custom")
    Grant::Adapter::Registry.for_url("c03custom:./x.db").should eq Grant::Adapter::Sqlite
  end

  it "establishes a connection from a URL alone and uses the inferred adapter" do
    Grant::ConnectionRegistry.establish_connection(database: "c03_url_only", url: "sqlite3::memory:", role: :writing)
    begin
      Grant::ConnectionRegistry.get_adapter("c03_url_only", :writing).should be_a Grant::Adapter::Sqlite
      Grant::ConnectionRegistry.connection_spec("c03_url_only", :writing).try(&.adapter_class).should eq Grant::Adapter::Sqlite
    ensure
      Grant::ConnectionRegistry.remove_connection("c03_url_only", :writing)
    end
  end

  it "still accepts an explicit adapter with a URL" do
    Grant::ConnectionRegistry.establish_connection(
      database: "c03_url_explicit", adapter: Grant::Adapter::Sqlite, url: "sqlite3::memory:", role: :writing)
    begin
      Grant::ConnectionRegistry.connection_exists?("c03_url_explicit", :writing).should be_true
    ensure
      Grant::ConnectionRegistry.remove_connection("c03_url_explicit", :writing)
    end
  end

  it "reports a missing scheme from establish_connection" do
    expect_raises(Grant::UnknownAdapterError) do
      Grant::ConnectionRegistry.establish_connection(database: "c03_url_bad", url: "nope://x/y")
    end
  end
end
