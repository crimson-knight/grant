require "./pool_spec_support"

# Holds *count* connections at once, then releases them all, so the pool has
# opened that many and must decide how many to keep idle.
private def hold_connections(adapter : Grant::Adapter::Base, count : Int32) : Nil
  ready = Channel(Nil).new
  release = Channel(Nil).new
  done = Channel(Nil).new
  count.times do
    spawn do
      adapter.open do |connection|
        connection.scalar("SELECT 1")
        ready.send(nil)
        release.receive
      end
      done.send(nil)
    end
  end
  count.times { ready.receive }
  count.times { release.send(nil) }
  count.times { done.receive }
end

describe "connection pool statistics" do
  after_each do
    Grant::ConnectionRegistry.remove_connection("c02_stats", :writing)
  end

  after_all { C02Support.cleanup }

  it "reports nothing for a pool that has not opened yet" do
    adapter = C02Support.establish("c02_stats", pool_size: 5)

    adapter.pool_stat.connections.should eq 0
    adapter.pool_stat.busy.should eq 0
    adapter.connected?.should be_false
  end

  it "reports size, open, busy and idle connections from the driver pool" do
    adapter = C02Support.establish("c02_stats", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5)

    inside = nil
    adapter.open do |connection|
      connection.scalar("SELECT 1")
      inside = adapter.pool_stat
    end

    inside.not_nil!.size.should eq 5
    inside.not_nil!.busy.should eq 1
    after = adapter.pool_stat
    after.busy.should eq 0
    after.idle.should eq after.connections
    adapter.database.pool.stats.open_connections.should eq after.connections
  end

  it "reuses idle connections instead of closing them when max_idle_pool_size allows" do
    adapter = C02Support.establish("c02_stats", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 3)

    hold_connections(adapter, 3)

    stat = adapter.pool_stat
    stat.connections.should eq 3
    stat.idle.should eq 3

    # A burst of three more checkouts finds all three connections idle.
    hold_connections(adapter, 3)
    adapter.pool_stat.connections.should eq 3
  end

  it "closes the surplus connections when max_idle_pool_size is smaller than the burst" do
    adapter = C02Support.establish("c02_stats", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 1)

    hold_connections(adapter, 3)

    adapter.pool_stat.connections.should eq 1
    adapter.pool_stat.idle.should eq 1
  end

  it "defaults max_idle_pool_size to pool_size for server adapters only" do
    spec = Grant::ConnectionRegistry::ConnectionSpec.new(
      "urls", Grant::Adapter::Pg, "postgres://localhost/app", :writing, pool_size: 25)
    URI.parse(spec.build_pool_url).query_params["max_idle_pool_size"].should eq "25"

    explicit = Grant::ConnectionRegistry::ConnectionSpec.new(
      "urls", Grant::Adapter::Pg, "postgres://localhost/app", :writing, pool_size: 25, max_idle_pool_size: 4)
    URI.parse(explicit.build_pool_url).query_params["max_idle_pool_size"].should eq "4"

    sqlite = Grant::ConnectionRegistry::ConnectionSpec.new(
      "urls", Grant::Adapter::Sqlite, "sqlite3:./app.db", :writing, pool_size: 25)
    URI.parse(sqlite.build_pool_url).query_params.has_key?("max_idle_pool_size").should be_false
  end

  it "lists every open pool through the registry, keyed by connection" do
    adapter = C02Support.establish("c02_stats", pool_size: 5, initial_pool_size: 1)
    adapter.open { |connection| connection.scalar("SELECT 1") }

    rows = Grant::ConnectionRegistry.pool_stats("c02_stats:writing")
    rows.size.should eq 1
    rows.first[:key].should eq "c02_stats:writing"
    rows.first[:max].should eq 5
    rows.first[:open].should be >= 1
    Grant::ConnectionRegistry.pool_stats.map { |row| row[:key] }.should contain "c02_stats:writing"
  end

  it "reads pool statistics without taking the registry lock" do
    # The provider runs while the registry holds its lock to build the adapter.
    # A statistics call that took the lock would deadlock right here.
    seen = nil
    url = C02Support.url("c02_stats")
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_stats", adapter: C02Support.adapter_class,
      url_provider: -> {
        seen = Grant::ConnectionRegistry.pool_stats
        Grant::ConnectionRegistry.get_load_balancer("c02_stats")
        url
      },
      role: :writing)

    Grant::ConnectionRegistry.get_adapter("c02_stats", :writing)
    seen.should_not be_nil
  end

  it "exposes the same numbers through Model.connection_pool" do
    C02Support.establish("c02_stats", pool_size: 7)
    pool = Grant::ConnectionPool.new(Grant::ConnectionRegistry.get_adapter("c02_stats", :writing))

    pool.connected?.should be_false
    pool.active?.should be_true
    pool.connected?.should be_true
    pool.stat.size.should eq 7
    pool.size.should eq 7
    pool.busy.should eq 0
    pool.waiting.should eq 0
  end
end
