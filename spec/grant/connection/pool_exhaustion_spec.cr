require "./pool_spec_support"

describe "connection pool exhaustion" do
  after_each do
    Grant::ConnectionRegistry.remove_connection("c02_exhaust", :writing)
    Grant::ConnectionRegistry.remove_connection("c02_memory", :writing)
  end

  after_all { C02Support.cleanup }

  it "raises Grant::ConnectionTimeoutError when a second fiber waits past the checkout timeout" do
    adapter = C02Support.establish("c02_exhaust", pool_size: 1, initial_pool_size: 1, checkout_timeout: 200.milliseconds)

    holder_ready = Channel(Nil).new
    release_holder = Channel(Nil).new
    finished = Channel(Nil).new
    spawn do
      adapter.open do |_|
        holder_ready.send(nil)
        release_holder.receive
      end
      finished.send(nil)
    end
    holder_ready.receive

    started = Time.instant
    error = expect_raises(Grant::ConnectionTimeoutError) do
      adapter.open(&.scalar("SELECT 1"))
    end
    (Time.instant - started).should be >= 150.milliseconds
    error.cause.should be_a(DB::PoolTimeout)

    release_holder.send(nil)
    finished.receive
    adapter.open(&.scalar("SELECT 1")).should eq 1
  end

  it "counts the blocked fiber as waiting while it waits" do
    adapter = C02Support.establish("c02_exhaust", pool_size: 1, initial_pool_size: 1, checkout_timeout: 2.seconds)

    holder_ready = Channel(Nil).new
    release_holder = Channel(Nil).new
    waiter_done = Channel(Nil).new
    spawn do
      adapter.open do |_|
        holder_ready.send(nil)
        release_holder.receive
      end
    end
    holder_ready.receive
    spawn do
      adapter.open(&.scalar("SELECT 1"))
      waiter_done.send(nil)
    end
    Fiber.yield

    stat = adapter.pool_stat
    stat.waiting.should eq 1
    stat.busy.should eq 1
    stat.exhausted?.should be_true

    release_holder.send(nil)
    waiter_done.receive
    adapter.pool_stat.waiting.should eq 0
  end

  it "forces a single connection for an in-memory SQLite database whatever pool_size says" do
    pending!("SQLite in-memory URLs only") unless CURRENT_ADAPTER == "sqlite"

    Grant::ConnectionRegistry.establish_connection(
      database: "c02_memory", adapter: Grant::Adapter::Sqlite, url: "sqlite3::memory:",
      role: :writing, pool_size: 10, initial_pool_size: 5)
    adapter = Grant::ConnectionRegistry.get_adapter("c02_memory", :writing)

    adapter.open { |connection| connection.exec("CREATE TABLE memory_marker (id INTEGER)") }
    adapter.open { |connection| connection.exec("INSERT INTO memory_marker VALUES (1)") }
    adapter.open { |connection| connection.scalar("SELECT COUNT(*) FROM memory_marker") }.should eq 1
    adapter.pool_stat.size.should eq 1
    adapter.pool_stat.connections.should eq 1
  end
end
