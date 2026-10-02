require "./pool_spec_support"

# An adapter whose health probe fails on demand and can be made slow, standing
# in for a database that goes down and comes back.
class C02FlakyAdapter < Grant::Adapter::Sqlite
  property? failing : Bool = false
  property probe_delay : Time::Span = 0.seconds
  getter probes : Int32 = 0

  def ping : Nil
    @probes += 1
    sleep @probe_delay if @probe_delay > 0.seconds
    raise IO::Error.new("connection refused") if failing?
  end
end

private def flaky_spec(**options) : Grant::ConnectionRegistry::ConnectionSpec
  Grant::ConnectionRegistry::ConnectionSpec.new(
    "c02_flaky", C02FlakyAdapter, "sqlite3::memory:", :writing, **options)
end

private def wait_until(timeout : Time::Span, &) : Nil
  deadline = Time.instant + timeout
  until yield
    break if Time.instant > deadline
    sleep 10.milliseconds
  end
end

private def fiber_count : Int32
  count = 0
  Fiber.each { count += 1 }
  count
end

describe Grant::HealthMonitor do
  after_each do
    Grant::ConnectionRegistry.clear_all
    Grant::HealthMonitor.test_mode = true
  end

  it "flips to unhealthy when the probe fails and back when it recovers" do
    adapter = C02FlakyAdapter.new("c02_flaky:writing", "sqlite3::memory:")
    monitor = Grant::HealthMonitor.new(adapter, flaky_spec)

    monitor.check_health_now.should be_true
    monitor.healthy?.should be_true

    adapter.failing = true
    monitor.check_health_now.should be_false
    monitor.healthy?.should be_false
    monitor.status[:healthy].should be_false
    expect_raises(Grant::ConnectionFailed) { monitor.verify! }

    adapter.failing = false
    monitor.check_health_now.should be_true
    monitor.healthy?.should be_true
    monitor.verify!
  end

  it "treats a probe that outlives health_check_timeout as unhealthy" do
    adapter = C02FlakyAdapter.new("c02_flaky:writing", "sqlite3::memory:")
    adapter.probe_delay = 300.milliseconds
    monitor = Grant::HealthMonitor.new(adapter, flaky_spec(health_check_timeout: 50.milliseconds))

    monitor.check_health_now.should be_false
    monitor.healthy?.should be_false
  end

  it "leaves no fiber behind after a probe times out and starts no second probe while one is stuck" do
    adapter = C02FlakyAdapter.new("c02_flaky:writing", "sqlite3::memory:")
    adapter.probe_delay = 250.milliseconds
    monitor = Grant::HealthMonitor.new(adapter, flaky_spec(health_check_timeout: 30.milliseconds))
    Fiber.yield
    baseline = fiber_count

    # Five checks while the first probe is still sleeping: one probe fiber.
    5.times { monitor.check_health_now.should be_false }
    adapter.probes.should eq 1
    fiber_count.should be <= baseline + 1

    # The stuck probe delivers into the buffered channel and exits.
    sleep 400.milliseconds
    fiber_count.should be <= baseline

    adapter.probe_delay = 0.seconds
    monitor.check_health_now.should be_true
    adapter.probes.should eq 2
  end

  it "recovers on the background timer and stops probing once stopped" do
    Grant::HealthMonitor.test_mode = false
    adapter = C02FlakyAdapter.new("c02_flaky:writing", "sqlite3::memory:")
    adapter.failing = true
    monitor = Grant::HealthMonitor.new(adapter, flaky_spec(health_check_interval: 20.milliseconds))
    monitor.start

    wait_until(2.seconds) { !monitor.healthy? }
    monitor.healthy?.should be_false

    adapter.failing = false
    wait_until(2.seconds) { monitor.healthy? }
    monitor.healthy?.should be_true

    monitor.stop
    probes_at_stop = adapter.probes
    sleep 100.milliseconds
    adapter.probes.should eq probes_at_stop
  end

  it "routes get_adapter away from an unhealthy connection and back once it recovers" do
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_health", adapter: C02Support.adapter_class, url: C02Support.url("c02_health"), role: :primary)
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_health", adapter: C02FlakyAdapter, url: "sqlite3::memory:", role: :writing)
    flaky = Grant::ConnectionRegistry.get_adapter("c02_health", :writing).as(C02FlakyAdapter)
    primary = Grant::ConnectionRegistry.get_adapter("c02_health", :primary)
    flaky.same?(primary).should be_false

    flaky.failing = true
    expect_raises(Grant::ConnectionFailed) { Grant::ConnectionRegistry.verify!("c02_health", :writing) }
    Grant::ConnectionRegistry.health_status.find! { |row| row[:key] == "c02_health:writing" }[:healthy].should be_false
    Grant::ConnectionRegistry.get_adapter("c02_health", :writing).same?(primary).should be_true

    flaky.failing = false
    Grant::ConnectionRegistry.verify!("c02_health", :writing)
    Grant::ConnectionRegistry.get_adapter("c02_health", :writing).same?(flaky).should be_true
    C02Support.cleanup
  end

  it "reports connected? without raising when the connection is down or missing" do
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_health", adapter: C02FlakyAdapter, url: "sqlite3::memory:", role: :writing)
    flaky = Grant::ConnectionRegistry.get_adapter("c02_health", :writing).as(C02FlakyAdapter)

    Grant::ConnectionRegistry.connected?("c02_health", :writing).should be_true
    flaky.failing = true
    Grant::ConnectionRegistry.connected?("c02_health", :writing).should be_false
    Grant::ConnectionRegistry.connected?("c02_health", :reading).should be_false
  end
end
