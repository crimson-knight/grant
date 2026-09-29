require "./pool_spec_support"

# An adapter that registers a connection while it is being disconnected.
# Registering takes the registry lock, so this raises (a mutex cannot be locked
# twice by one fiber) if the registry still held its lock while closing.
class C02LockProbeAdapter < Grant::Adapter::Sqlite
  class_property lookups : Int32 = 0

  def disconnect! : Nil
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_probe_#{@@lookups}", adapter: Grant::Adapter::Sqlite, url: "sqlite3::memory:", role: :writing)
    C02LockProbeAdapter.lookups += 1
    super
  end
end

class C02DisconnectModel < Grant::Base
  table c02_disconnect_models
  column id : Int64, primary: true
  connects_to database: "c02_disconnect"
end

private def used_adapter(role : Symbol = :writing) : Grant::Adapter::Base
  adapter = C02Support.establish("c02_disconnect", role, pool_size: 3)
  adapter.open { |connection| connection.scalar("SELECT 1") }
  adapter
end

describe "connection teardown" do
  after_each do
    Grant::ConnectionRegistry.clear_all
    C02LockProbeAdapter.lookups = 0
  end

  after_all { C02Support.cleanup }

  it "closes the old pool when a connection is replaced" do
    adapter = used_adapter
    old_pool = adapter.database
    old_pool.pool.stats.open_connections.should be > 0

    replacement = used_adapter

    replacement.same?(adapter).should be_false
    old_pool.pool.stats.open_connections.should eq 0
    adapter.connected?.should be_false
    replacement.connected?.should be_true
  end

  it "closes every pool on clear_all" do
    writer = used_adapter(:writing)
    reader = used_adapter(:reading)
    pools = [writer.database, reader.database]

    Grant::ConnectionRegistry.clear_all

    pools.each { |pool| pool.pool.stats.open_connections.should eq 0 }
    Grant::ConnectionRegistry.adapter_names.should be_empty
    Grant::ConnectionRegistry.connection_exists?("c02_disconnect", :writing).should be_false
  end

  it "removes one connection, stops its monitor and closes its pool" do
    adapter = used_adapter
    pool = adapter.database
    Grant::HealthMonitorRegistry.get("c02_disconnect:writing").should_not be_nil

    Grant::ConnectionRegistry.remove_connection("c02_disconnect", :writing).should be_true

    pool.pool.stats.open_connections.should eq 0
    Grant::HealthMonitorRegistry.get("c02_disconnect:writing").should be_nil
    Grant::ConnectionRegistry.connection_exists?("c02_disconnect", :writing).should be_false
    Grant::ConnectionRegistry.remove_connection("c02_disconnect", :writing).should be_false
  end

  it "drops a removed replica from the load balancer, and the balancer with the last one" do
    used_adapter(:reading)
    Grant::ConnectionRegistry.get_load_balancer("c02_disconnect").not_nil!.size.should eq 1

    Grant::ConnectionRegistry.remove_connection("c02_disconnect", :reading)

    Grant::ConnectionRegistry.get_load_balancer("c02_disconnect").should be_nil
  end

  it "closes pools after the registry lock is released" do
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_disconnect", adapter: C02LockProbeAdapter, url: C02Support.url("c02_disconnect"), role: :writing)
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_disconnect", adapter: C02LockProbeAdapter, url: C02Support.url("c02_disconnect"), role: :writing)
    C02LockProbeAdapter.lookups.should eq 1

    Grant::ConnectionRegistry.remove_connection("c02_disconnect", :writing)
    C02LockProbeAdapter.lookups.should eq 2

    Grant::ConnectionRegistry.establish_connection(
      database: "c02_disconnect", adapter: C02LockProbeAdapter, url: C02Support.url("c02_disconnect"), role: :writing)
    Grant::ConnectionRegistry.clear_all
    C02LockProbeAdapter.lookups.should eq 3
  end

  it "keeps connections registered on disconnect_all! and reopens them on next use" do
    adapter = used_adapter

    Grant::ConnectionRegistry.disconnect_all!

    adapter.connected?.should be_false
    Grant::ConnectionRegistry.connection_exists?("c02_disconnect", :writing).should be_true
    adapter.open { |connection| connection.scalar("SELECT 1") }.should eq 1
    adapter.connected?.should be_true
  end

  it "reopens a disconnected adapter that something still references" do
    adapter = used_adapter
    adapter.disconnect!
    adapter.pool_stat.connections.should eq 0

    adapter.open { |connection| connection.scalar("SELECT 1") }.should eq 1
  end

  describe "on the model" do
    it "establishes, inspects, disconnects and removes the model's connection" do
      C02DisconnectModel.establish_connection(
        url: C02Support.url("c02_disconnect"), adapter: C02Support.adapter_class, pool_size: 4)

      C02DisconnectModel.connected?.should be_true
      C02DisconnectModel.connection_pool.stat.size.should eq 4
      C02DisconnectModel.retrieve_connection_pool.should_not be_nil

      C02DisconnectModel.disconnect!
      C02DisconnectModel.connection_pool.connected?.should be_false

      C02DisconnectModel.remove_connection.should be_true
      C02DisconnectModel.retrieve_connection_pool.should be_nil
      C02DisconnectModel.connected?.should be_false
      C02DisconnectModel.remove_connection.should be_false
    end
  end
end
