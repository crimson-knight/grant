require "./pool_spec_support"

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

private def wait_until(timeout : Time::Span, &) : Nil
  deadline = Time.instant + timeout
  until yield
    break if Time.instant > deadline
    sleep 10.milliseconds
  end
end

describe Grant::PoolReaper do
  after_each do
    Grant::ConnectionRegistry.remove_connection("c02_reaper", :writing)
  end

  after_all { C02Support.cleanup }

  it "leaves connections alone until nothing was checked out for idle_timeout" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, idle_timeout: 60.milliseconds)
    hold_connections(adapter, 3)
    reaper = Grant::PoolReaper.new(adapter, 1.minute)

    reaper.sweep.should eq 0
    adapter.pool_stat.idle.should eq 3

    sleep 90.milliseconds
    reaper.sweep.should eq 3
    adapter.pool_stat.connections.should eq 0
  end

  it "keeps min_connections open when it closes idle ones" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, idle_timeout: 30.milliseconds, min_connections: 2)
    hold_connections(adapter, 4)
    sleep 60.milliseconds

    Grant::PoolReaper.new(adapter, 1.minute).sweep.should eq 2

    adapter.pool_stat.connections.should eq 2
    adapter.pool_stat.idle.should eq 2
    adapter.open(&.scalar("SELECT 1")).should eq 1
  end

  it "does not touch connections that are checked out" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, idle_timeout: 20.milliseconds)
    hold_connections(adapter, 3)

    adapter.open do |connection|
      sleep 50.milliseconds
      Grant::PoolReaper.new(adapter, 1.minute).sweep
      connection.scalar("SELECT 1").should eq 1
    end
  end

  it "retires idle connections that outlived max_age" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, max_age: 250.milliseconds)
    hold_connections(adapter, 3)
    reaper = Grant::PoolReaper.new(adapter, 1.minute)

    reaper.sweep.should eq 0
    sleep 300.milliseconds
    reaper.sweep.should eq 3
    adapter.pool_stat.connections.should eq 0
    adapter.open(&.scalar("SELECT 1")).should eq 1
  end

  it "closes a connection that passed max_age while it was checked out when it is returned" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, max_age: 250.milliseconds)

    adapter.open do |connection|
      sleep 300.milliseconds
      connection.scalar("SELECT 1").should eq 1
    end

    adapter.pool_stat.connections.should eq 0
  end

  it "pings idle connections on the keepalive interval" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5, keepalive: 20.milliseconds)
    hold_connections(adapter, 3)

    adapter.keepalive_idle_connections.should eq 3
    adapter.pool_stat.idle.should eq 3
    adapter.pool_stat.busy.should eq 0
  end

  it "does nothing without idle_timeout or keepalive" do
    adapter = C02Support.establish("c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5)
    hold_connections(adapter, 3)

    Grant::PoolReaper.new(adapter, 1.minute).sweep.should eq 0
    adapter.pool_stat.idle.should eq 3
  end

  it "sweeps on its own timer once the registry starts it, and stops when the connection is removed" do
    Grant::HealthMonitor.test_mode = false
    adapter = C02Support.establish(
      "c02_reaper", pool_size: 5, initial_pool_size: 1, max_idle_pool_size: 5,
      idle_timeout: 30.milliseconds, reaping_frequency: 20.milliseconds,
      health_check_interval: 1.hour)
    hold_connections(adapter, 3)
    adapter.pool_stat.connections.should eq 3

    wait_until(2.seconds) { adapter.pool_stat.connections == 0 }
    adapter.pool_stat.connections.should eq 0

    Grant::ConnectionRegistry.remove_connection("c02_reaper", :writing)
    Grant::HealthMonitor.test_mode = true
  end
end
