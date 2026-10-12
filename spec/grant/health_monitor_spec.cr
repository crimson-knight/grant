require "../spec_helper"

module Grant::HealthMonitorSpec
  {% if flag?(:preview_mt) || flag?(:execution_context) %}
    class AwaitHealthResultPublicationReleaseChannel < Channel(Bool)
      getter has_released_publication = Atomic(Bool).new(false)

      def initialize
        super(1)
      end

      def send(value : Bool) : self
        super(value)
        until has_released_publication.get
          Thread.sleep(1.millisecond)
        end
        self
      end
    end

    class MonitorHealthWithPublicationGate < Grant::HealthMonitor
      @has_supplied_publication_channel = false

      def initialize(adapter : Grant::Adapter::Base, configuration : Grant::ConnectionRegistry::ConnectionSpec,
                     @publication_channel : AwaitHealthResultPublicationReleaseChannel)
        super(adapter, configuration)
      end

      private def create_health_result_channel : Channel(Bool)
        if @has_supplied_publication_channel
          super
        else
          @has_supplied_publication_channel = true
          @publication_channel
        end
      end
    end
  {% end %}

  class AwaitHealthProbeReleaseAdapter < Grant::Adapter::Sqlite
    getter query_count = Atomic(Int32).new(0)
    getter active_query_count = Atomic(Int32).new(0)
    getter has_overlapping_queries = Atomic(Bool).new(false)
    getter has_released_query = Atomic(Bool).new(false)

    def open(&)
      query_count.add(1)
      previous_count = active_query_count.add(1)
      has_overlapping_queries.set(true) if previous_count > 0
      until has_released_query.get
        {% if flag?(:preview_mt) || flag?(:execution_context) %}
          Thread.sleep(1.millisecond)
        {% else %}
          sleep 1.millisecond
        {% end %}
      end
      super { |connection| yield connection }
    ensure
      active_query_count.sub(1)
    end
  end
end

private def create_health_monitor_for_spec(adapter : Grant::Adapter::Base) : Grant::HealthMonitor
  configuration = Grant::ConnectionRegistry::ConnectionSpec.new(
    "health_monitor_spec",
    Grant::Adapter::Sqlite,
    adapter.url,
    :primary,
    pool_size: 1,
    initial_pool_size: 1,
    health_check_timeout: 20.milliseconds
  )
  Grant::HealthMonitor.new(adapter, configuration)
end

private def wait_until_health_probe_completes(monitor : Grant::HealthMonitor) : Nil
  deadline = Time.instant + 1.second
  while monitor.has_health_query_in_flight?
    raise "The controlled health probe retained its execution after release" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

private def count_owned_health_threads(adapter_name : String) : Int32
  count = 0
  Thread.each do |thread|
    count += 1 if thread.name == "grant-health-#{adapter_name}"
  end
  count
end

{% if flag?(:execution_context) %}
  private def count_owned_health_contexts(adapter_name : String) : Int32
    count = 0
    Fiber::ExecutionContext.each do |context|
      count += 1 if context.name == "grant-health-#{adapter_name}"
    end
    count
  end
{% end %}

describe Grant::HealthMonitor do
  describe "#check_health_now" do
    it "checks an available real SQLite connection repeatedly" do
      adapter = Grant::Adapter::Sqlite.new(name: "available_health_probe", url: "sqlite3::memory:")
      monitor = create_health_monitor_for_spec(adapter)
      4.times do
        monitor.check_health_now.should be_true
        monitor.healthy?.should be_true
        wait_until_health_probe_completes(monitor)
      end
      adapter.database.close
    end

    it "starts immediate successive checks after each available database result" do
      adapter = Grant::Adapter::Sqlite.new(name: "immediate_health_probe", url: "sqlite3::memory:")
      monitor = create_health_monitor_for_spec(adapter)
      begin
        100.times { monitor.check_health_now.should be_true }
      ensure
        wait_until_health_probe_completes(monitor)
        adapter.database.close
      end
    end

    it "reports an actually unavailable SQLite path as unhealthy and releases query ownership" do
      adapter = Grant::Adapter::Sqlite.new(name: "unavailable_health_probe", url: "sqlite3:/dev/null/unavailable.sqlite3")
      monitor = create_health_monitor_for_spec(adapter)
      monitor.check_health_now.should be_false
      monitor.healthy?.should be_false
      wait_until_health_probe_completes(monitor)
    end

    it "keeps a timed-out query singly owned and permits recovery after its late result" do
      adapter = Grant::HealthMonitorSpec::AwaitHealthProbeReleaseAdapter.new(name: "late_health_probe", url: "sqlite3::memory:")
      monitor = create_health_monitor_for_spec(adapter)
      begin
        monitor.check_health_now.should be_false
        monitor.healthy?.should be_false
        monitor.has_health_query_in_flight?.should be_true
        5.times { monitor.check_health_now.should be_false }
        adapter.query_count.get.should eq(1)
        adapter.has_overlapping_queries.get.should be_false

        adapter.has_released_query.set(true)
        wait_until_health_probe_completes(monitor)
        adapter.active_query_count.get.should eq(0)
        monitor.check_health_now.should be_true
        wait_until_health_probe_completes(monitor)
        monitor.healthy?.should be_true
        adapter.query_count.get.should eq(2)
        adapter.has_overlapping_queries.get.should be_false

        {% if flag?(:execution_context) %}
          deadline = Time.instant + 1.second
          while count_owned_health_contexts(adapter.name) > 0
            raise "The controlled health context survived its late completion" if Time.instant >= deadline
            sleep 1.millisecond
          end
          count_owned_health_contexts(adapter.name).should eq(0)
        {% elsif flag?(:preview_mt) %}
          deadline = Time.instant + 1.second
          while count_owned_health_threads(adapter.name) > 0
            raise "The controlled health thread survived its late completion" if Time.instant >= deadline
            sleep 1.millisecond
          end
          count_owned_health_threads(adapter.name).should eq(0)
        {% end %}
      ensure
        adapter.has_released_query.set(true)
        wait_until_health_probe_completes(monitor)
        adapter.database.close
      end
    end

    {% if flag?(:preview_mt) || flag?(:execution_context) %}
      it "publishes a result and releases query ownership before the observer's immediate next check" do
        adapter = Grant::Adapter::Sqlite.new(name: "publication_health_probe", url: "sqlite3::memory:")
        configuration = Grant::ConnectionRegistry::ConnectionSpec.new(
          "publication_health_probe", Grant::Adapter::Sqlite, adapter.url, :primary,
          pool_size: 1, initial_pool_size: 1, health_check_timeout: 1.second
        )
        channel = Grant::HealthMonitorSpec::AwaitHealthResultPublicationReleaseChannel.new
        monitor = Grant::HealthMonitorSpec::MonitorHealthWithPublicationGate.new(adapter, configuration, channel)
        has_started_next_check = Atomic(Bool).new(false)
        has_completed_checks = Atomic(Bool).new(false)
        list_of_health_results = [] of Bool
        releaser = Thread.new(name: "health-publication-release-control") do
          until has_started_next_check.get || channel.has_released_publication.get
            Thread.sleep(1.millisecond)
          end
          Thread.sleep(20.milliseconds)
          channel.has_released_publication.set(true)
        end
        {% if flag?(:execution_context) %}
          worker = Fiber::ExecutionContext::Isolated.new("health-publication-observer") do
            list_of_health_results << monitor.check_health_now
            has_started_next_check.set(true)
            list_of_health_results << monitor.check_health_now
            has_completed_checks.set(true)
          end
        {% else %}
          spawn(name: "health-publication-observer") do
            list_of_health_results << monitor.check_health_now
            has_started_next_check.set(true)
            list_of_health_results << monitor.check_health_now
            has_completed_checks.set(true)
          end
        {% end %}
        begin
          deadline = Time.instant + 1.second
          until has_completed_checks.get
            raise "The controlled observer did not complete its immediate checks" if Time.instant >= deadline
            sleep 1.millisecond
          end
        ensure
          channel.has_released_publication.set(true)
        end
        releaser.join
        {% if flag?(:execution_context) %}
          worker.wait
        {% end %}
        list_of_health_results.should eq([true, true])
        wait_until_health_probe_completes(monitor)
        adapter.database.close
      end

      it "keeps real database health available while the native main thread stays blocked" do
        adapter = Grant::Adapter::Sqlite.new(name: "blocked_main_health_probe", url: "sqlite3::memory:")
        monitor = create_health_monitor_for_spec(adapter)
        list_of_health_results = [] of Bool
        {% if flag?(:execution_context) %}
          has_completed = Atomic(Bool).new(false)
          worker = Fiber::ExecutionContext::Isolated.new("health-observer-control") do
            4.times { list_of_health_results << monitor.check_health_now }
            has_completed.set(true)
          end
          deadline = Time.instant + 1.second
          until has_completed.get
            raise "The isolated health observer did not finish with the native main thread blocked" if Time.instant >= deadline
            Thread.sleep(1.millisecond)
          end
          worker.wait
        {% else %}
          worker = Thread.new(name: "health-observer-control") do
            4.times { list_of_health_results << monitor.check_health_now }
          end
          worker.join
        {% end %}
        list_of_health_results.should eq([true, true, true, true])
        monitor.healthy?.should be_true
        wait_until_health_probe_completes(monitor)
        adapter.database.close
      end
    {% end %}
  end
end
