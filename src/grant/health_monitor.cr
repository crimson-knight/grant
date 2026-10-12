require "log"

module Grant
  # Monitors database connection health
  class HealthMonitor
    Log = ::Log.for("grant.health_monitor")

    # Test mode flag to disable background operations
    class_property test_mode : Bool = false # ameba:disable Naming/QueryBoolMethods
    # The existing test_mode reader/setter remain source-compatible for consumers.

    @adapter : Grant::Adapter::Base
    @config : ConnectionRegistry::ConnectionSpec
    @healthy : Atomic(Bool) = Atomic(Bool).new(true)
    @last_check_timestamp : Atomic(Int64) = Atomic(Int64).new(Time.utc.to_unix)
    @check_fiber : Fiber?
    @running : Atomic(Bool) = Atomic(Bool).new(false)
    @query_mutex = Thread::Mutex.new
    @has_health_query_in_flight = false

    def initialize(@adapter : Grant::Adapter::Base, @config : ConnectionRegistry::ConnectionSpec)
    end

    def start
      return if @@test_mode || @running.get

      @running.set(true)
      @check_fiber = spawn do
        loop do
          sleep @config.health_check_interval
          break unless @running.get
          check_health
        end
      end

      Log.debug { "Started health monitoring for #{@adapter.name}" }
    end

    def stop
      @running.set(false)
      @check_fiber.try(&.enqueue)
      Log.debug { "Stopped health monitoring for #{@adapter.name}" }
    end

    def healthy? : Bool
      @healthy.get
    end

    def last_check_time : Time
      Time.unix(@last_check_timestamp.get)
    end

    # Checks the database now and returns the observed health result.
    # A timed-out query remains owned until its execution completes.
    #
    # ```
    # monitor.check_health_now # => true when the database answers in time
    # ```
    def check_health_now : Bool
      check_health
    end

    # Reports whether an earlier database probe still owns its execution.
    # A timed-out probe remains owned until its database operation completes.
    #
    # ```
    # monitor.check_health_now
    # monitor.has_health_query_in_flight?
    # ```
    def has_health_query_in_flight? : Bool
      @query_mutex.synchronize { @has_health_query_in_flight }
    end

    private def check_health : Bool
      Log.trace { "Checking health for #{@adapter.name}" }

      begin
        # Perform health check with timeout
        # A buffered result lets a late probe finish after its observer times
        # out. Its ownership flag keeps repeated checks at one active probe.
        channel = create_health_result_channel
        return false unless start_health_query(channel)

        select
        when result = channel.receive
          previous_health = @healthy.get
          @healthy.set(result)
          @last_check_timestamp.set(Time.utc.to_unix)

          # Log state changes
          if previous_health && !result
            Log.error { "Connection #{@adapter.name} became unhealthy" }
          elsif !previous_health && result
            Log.info { "Connection #{@adapter.name} recovered and is now healthy" }
          end

          result
        when timeout(@config.health_check_timeout)
          previous_health = @healthy.get
          @healthy.set(false)
          @last_check_timestamp.set(Time.utc.to_unix)

          if previous_health
            Log.error { "Health check timeout for #{@adapter.name} (timeout: #{@config.health_check_timeout})" }
          end

          false
        end
      rescue ex
        @healthy.set(false)
        @last_check_timestamp.set(Time.utc.to_unix)
        Log.error(exception: ex) { "Health check failed for #{@adapter.name}" }
        false
      end
    end

    private def create_health_result_channel : Channel(Bool)
      Channel(Bool).new(1)
    end

    private def start_health_query(channel : Channel(Bool)) : Bool
      has_claimed_query = @query_mutex.synchronize do
        if @has_health_query_in_flight
          false
        else
          @has_health_query_in_flight = true
          true
        end
      end
      return false unless has_claimed_query

      {% if flag?(:execution_context) %}
        # An isolated context owns a native thread and supports pool/channel
        # waits throughout the probe on the execution-context runtime.
        Fiber::ExecutionContext::Isolated.new("grant-health-#{@adapter.name}") do
          perform_health_query(channel)
        end
      {% elsif flag?(:preview_mt) %}
        # Native GUI loops occupy their main scheduler. A real thread keeps
        # the probe independent of preview_mt's round-robin main-worker slot.
        Thread.new(name: "grant-health-#{@adapter.name}") do
          perform_health_query(channel)
        end
      {% else %}
        # Single-thread consumers preserve their cooperative fiber runtime.
        spawn(name: "grant-health-#{@adapter.name}") do
          perform_health_query(channel)
        end
      {% end %}
      true
    rescue ex : Exception
      @query_mutex.synchronize { @has_health_query_in_flight = false }
      raise ex
    end

    private def perform_health_query(channel : Channel(Bool)) : Nil
      result = false
      begin
        @adapter.open(&.scalar("SELECT 1"))
        result = true
      rescue ex : Exception
        Log.warn { "Health check query failed for #{@adapter.name}: #{ex.message}" }
      ensure
        # The observer sees a completed result together with released query
        # ownership, so its immediate next check can start a fresh probe.
        @query_mutex.synchronize do
          channel.send(result)
          @has_health_query_in_flight = false
        end
      end
    end

    # Get health status summary
    def status : NamedTuple(healthy: Bool, last_check: Time, adapter: String)
      {
        healthy:    @healthy.get,
        last_check: @last_check.get,
        adapter:    @adapter.name,
      }
    end
  end

  # Manages health monitors for all connections
  class HealthMonitorRegistry
    @@monitors = {} of String => HealthMonitor
    @@mutex = Mutex.new

    def self.register(key : String, adapter : Grant::Adapter::Base, config : ConnectionRegistry::ConnectionSpec)
      @@mutex.synchronize do
        # Stop existing monitor if any
        @@monitors[key]?.try(&.stop)

        # Create and start new monitor
        monitor = HealthMonitor.new(adapter, config)
        monitor.start unless HealthMonitor.test_mode
        @@monitors[key] = monitor
      end
    end

    def self.unregister(key : String)
      @@mutex.synchronize do
        @@monitors[key]?.try(&.stop)
        @@monitors.delete(key)
      end
    end

    def self.get(key : String) : HealthMonitor?
      @@mutex.synchronize { @@monitors[key]? }
    end

    def self.all_healthy? : Bool
      @@mutex.synchronize do
        @@monitors.values.all?(&.healthy?)
      end
    end

    def self.healthy_connections : Array(String)
      @@mutex.synchronize do
        @@monitors.select { |_, monitor| monitor.healthy? }.keys
      end
    end

    def self.unhealthy_connections : Array(String)
      @@mutex.synchronize do
        @@monitors.reject { |_, monitor| monitor.healthy? }.keys
      end
    end

    def self.status : Array(NamedTuple(key: String, healthy: Bool, last_check: Time))
      @@mutex.synchronize do
        @@monitors.map do |key, monitor|
          {
            key:        key,
            healthy:    monitor.healthy?,
            last_check: monitor.last_check_time,
          }
        end
      end
    end

    def self.clear
      @@mutex.synchronize do
        @@monitors.values.each(&.stop)
        @@monitors.clear
      end
    end
  end
end
