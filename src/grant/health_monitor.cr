require "log"

module Grant
  # Monitors database connection health
  class HealthMonitor
    Log = ::Log.for("grant.health_monitor")

    # Test mode flag to disable background operations
    class_property test_mode : Bool = false

    @adapter : Grant::Adapter::Base
    @config : ConnectionRegistry::ConnectionSpec
    @healthy : Atomic(Bool) = Atomic(Bool).new(true)
    @last_check_timestamp : Atomic(Int64) = Atomic(Int64).new(Time.utc.to_unix)
    @check_fiber : Fiber?
    @running : Atomic(Bool) = Atomic(Bool).new(false)
    # True while a probe fiber is still working. At most one probe runs per
    # monitor, so an outage cannot pile up blocked fibers.
    @probing : Atomic(Bool) = Atomic(Bool).new(false)
    @stop_signal = Channel(Nil).new(1)

    def initialize(@adapter : Grant::Adapter::Base, @config : ConnectionRegistry::ConnectionSpec)
    end

    def start
      return if @@test_mode || @running.swap(true)

      @check_fiber = spawn do
        loop do
          select
          when @stop_signal.receive
            break
          when timeout(@config.health_check_interval)
            break unless @running.get
            check_health
          end
        end
      end

      Log.debug { "Started health monitoring for #{@adapter.name}" }
    end

    def stop
      return unless @running.swap(false)

      select
      when @stop_signal.send(nil)
      else
      end
      Log.debug { "Stopped health monitoring for #{@adapter.name}" }
    end

    def healthy? : Bool
      @healthy.get
    end

    def last_check_time : Time
      Time.unix(@last_check_timestamp.get)
    end

    # Probes the adapter now and returns whether it answered.
    def check_health_now : Bool
      check_health
    end

    # Probes the adapter now and raises `Grant::ConnectionFailed` when it did
    # not answer.
    def verify! : Nil
      return if check_health
      raise Grant::ConnectionFailed.new("Connection #{@adapter.name} failed its health check")
    end

    private def check_health : Bool
      Log.trace { "Checking health for #{@adapter.name}" }

      # A probe from an earlier check is still stuck: the connection is
      # unresponsive, and starting another fiber would only add to the pile.
      if @probing.swap(true)
        record_result(false, "previous health check still running")
        return false
      end

      # Buffered so the probe fiber can always deliver its answer and exit, even
      # after this method gave up waiting.
      channel = Channel(Bool).new(1)

      spawn do
        answered = begin
          @adapter.verify!
          true
        rescue ex
          Log.warn { "Health check query failed for #{@adapter.name}: #{ex.message}" }
          false
        end
        @probing.set(false)
        channel.send(answered)
      end

      select
      when result = channel.receive
        record_result(result, nil)
      when timeout(@config.health_check_timeout)
        record_result(false, "timed out (timeout: #{@config.health_check_timeout})")
      end
    end

    private def record_result(result : Bool, failure : String?) : Bool
      previous_health = @healthy.swap(result)
      @last_check_timestamp.set(Time.utc.to_unix)

      if previous_health && !result
        Log.error { "Connection #{@adapter.name} became unhealthy#{failure ? ": #{failure}" : ""}" }
      elsif !previous_health && result
        Log.info { "Connection #{@adapter.name} recovered and is now healthy" }
      end

      result
    end

    # Get health status summary
    def status : NamedTuple(healthy: Bool, last_check: Time, adapter: String)
      {
        healthy:    @healthy.get,
        last_check: Time.unix(@last_check_timestamp.get),
        adapter:    @adapter.name,
      }
    end
  end

  # Manages health monitors for all connections.
  #
  # Reads (`get`, the health predicates) see an immutable hash that writers
  # replace, so resolving an adapter never waits on a lock.
  class HealthMonitorRegistry
    @@monitors = {} of String => HealthMonitor
    @@mutex = Mutex.new

    def self.register(key : String, adapter : Grant::Adapter::Base, config : ConnectionRegistry::ConnectionSpec)
      previous = nil
      monitor = HealthMonitor.new(adapter, config)
      @@mutex.synchronize do
        previous = @@monitors[key]?
        updated = @@monitors.dup
        updated[key] = monitor
        @@monitors = updated
      end

      # Stop the old monitor and start the new one outside the lock.
      previous.try(&.stop)
      monitor.start unless HealthMonitor.test_mode
    end

    def self.unregister(key : String)
      removed = nil
      @@mutex.synchronize do
        removed = @@monitors[key]?
        if removed
          updated = @@monitors.dup
          updated.delete(key)
          @@monitors = updated
        end
      end
      removed.try(&.stop)
    end

    def self.get(key : String) : HealthMonitor?
      @@monitors[key]?
    end

    def self.all_healthy? : Bool
      @@monitors.each_value.all?(&.healthy?)
    end

    def self.healthy_connections : Array(String)
      @@monitors.select { |_, monitor| monitor.healthy? }.keys
    end

    def self.unhealthy_connections : Array(String)
      @@monitors.reject { |_, monitor| monitor.healthy? }.keys
    end

    def self.status : Array(NamedTuple(key: String, healthy: Bool, last_check: Time))
      @@monitors.map do |key, monitor|
        {
          key:        key,
          healthy:    monitor.healthy?,
          last_check: monitor.last_check_time,
        }
      end
    end

    def self.clear
      stopped = @@mutex.synchronize do
        current = @@monitors
        @@monitors = {} of String => HealthMonitor
        current
      end
      stopped.each_value(&.stop)
    end
  end
end
