require "log"

module Grant
  # One read replica in a `ReplicaLoadBalancer`: its adapter, the registry key
  # it was registered under, its health monitor and its weight.
  class ReplicaEntry
    getter adapter : Grant::Adapter::Base
    getter key : String
    getter monitor : HealthMonitor?
    getter weight : Int32

    def initialize(@adapter, @key = adapter.name, @monitor = nil, weight : Int32 = 1)
      @weight = Math.max(weight, 1)
    end

    # True when the replica has no monitor or its monitor reports healthy.
    def healthy? : Bool
      monitor = @monitor
      monitor.nil? || monitor.healthy?
    end
  end

  # Load balancing strategies for read replicas.
  #
  # A strategy chooses among the healthy entries of an immutable array in
  # `#pick`, which allocates nothing. `#next_index` is the lower-level hook the
  # index-based strategies implement.
  abstract class LoadBalancingStrategy
    abstract def next_index(total : Int32) : Int32
    abstract def reset

    # Chooses one healthy entry, or nil when none is healthy.
    def pick(entries : Array(ReplicaEntry)) : ReplicaEntry?
      healthy = 0
      last_healthy = nil
      entries.each do |entry|
        next unless entry.healthy?
        healthy += 1
        last_healthy = entry
      end
      return nil if healthy == 0
      return last_healthy if healthy == 1

      wanted = next_index(healthy)
      seen = 0
      entries.each do |entry|
        next unless entry.healthy?
        return entry if seen == wanted
        seen += 1
      end
      last_healthy
    end
  end

  # Round-robin load balancing
  class RoundRobinStrategy < LoadBalancingStrategy
    @current_index : Atomic(Int32) = Atomic(Int32).new(-1)

    def next_index(total : Int32) : Int32
      return 0 if total == 1
      (@current_index.add(1) + 1) % total
    end

    def reset
      @current_index.set(-1)
    end
  end

  # Random load balancing
  class RandomStrategy < LoadBalancingStrategy
    def next_index(total : Int32) : Int32
      Random.rand(total)
    end

    def reset
      # No state to reset
    end
  end

  # Sends each read to the healthy replica with the fewest connections checked
  # out right now. The count is the adapter's own `active_checkouts`, which
  # `Adapter#open_pool_connection` raises when it takes a connection and lowers
  # in an `ensure` when it gives it back, so it can neither drift nor grow
  # without bound.
  class LeastConnectionsStrategy < LoadBalancingStrategy
    @tie_breaker : Atomic(Int32) = Atomic(Int32).new(0)
    @connection_counts : Hash(Int32, Int32) = {} of Int32 => Int32
    @mutex = Mutex.new

    def pick(entries : Array(ReplicaEntry)) : ReplicaEntry?
      # Start from a rotating offset so equally idle replicas share the load.
      size = entries.size
      return nil if size == 0

      start = (@tie_breaker.add(1) + 1) % size
      best = nil
      best_count = Int32::MAX
      size.times do |step|
        entry = entries.unsafe_fetch((start + step) % size)
        next unless entry.healthy?
        count = entry.adapter.active_checkouts
        if count < best_count
          best = entry
          best_count = count
        end
      end
      best
    end

    # Index-based selection over a caller-tracked count, kept for callers that
    # drive the strategy directly. `ReplicaLoadBalancer` uses `#pick`.
    def next_index(total : Int32) : Int32
      @mutex.synchronize do
        (0...total).each { |i| @connection_counts[i] ||= 0 }

        min_index = 0
        min_count = @connection_counts[0]
        (1...total).each do |i|
          count = @connection_counts[i]
          if count < min_count
            min_count = count
            min_index = i
          end
        end

        @connection_counts[min_index] += 1
        min_index
      end
    end

    # Gives back the connection `#next_index` counted for *index*.
    def release_connection(index : Int32)
      @mutex.synchronize do
        if count = @connection_counts[index]?
          @connection_counts[index] = Math.max(count - 1, 0)
        end
      end
    end

    def reset
      @mutex.synchronize do
        @connection_counts.clear
      end
    end
  end

  # Weighted round-robin: a replica registered with `weight: 3` receives three
  # reads for each one sent to a replica with weight 1.
  class WeightedStrategy < LoadBalancingStrategy
    @cursor : Atomic(Int64) = Atomic(Int64).new(-1)

    def next_index(total : Int32) : Int32
      (@cursor.add(1) + 1).to_i32.abs % total
    end

    def pick(entries : Array(ReplicaEntry)) : ReplicaEntry?
      total_weight = 0
      entries.each { |entry| total_weight += entry.weight if entry.healthy? }
      return nil if total_weight == 0

      slot = ((@cursor.add(1) + 1) % total_weight).to_i32
      entries.each do |entry|
        next unless entry.healthy?
        return entry if slot < entry.weight
        slot -= entry.weight
      end
      nil
    end

    def reset
      @cursor.set(-1)
    end
  end

  # Manages load balancing across read replicas.
  #
  # The replica list is an immutable array that registration and removal swap
  # for a new one, so choosing a replica reads it without a lock.
  class ReplicaLoadBalancer
    Log = ::Log.for("grant.replica_load_balancer")

    @entries : Array(ReplicaEntry)
    @strategy : LoadBalancingStrategy
    @write_mutex = Mutex.new

    def initialize(adapters : Array(Grant::Adapter::Base), @strategy : LoadBalancingStrategy = RoundRobinStrategy.new)
      @entries = adapters.map { |adapter| ReplicaEntry.new(adapter) }
    end

    # Adds a replica to the pool. Registering a replica under a key that is
    # already present replaces the earlier entry instead of adding a second one.
    def add_replica(adapter : Grant::Adapter::Base, monitor : HealthMonitor? = nil, key : String = adapter.name, weight : Int32 = 1) : Grant::Adapter::Base?
      replaced = nil
      @write_mutex.synchronize do
        updated = @entries.reject { |entry| entry.key == key && (replaced = entry.adapter) }
        updated << ReplicaEntry.new(adapter, key, monitor, weight)
        @entries = updated
      end
      Log.info { "Added replica #{key} to load balancer" }
      replaced
    end

    # Remove a replica from the pool
    def remove_replica(adapter : Grant::Adapter::Base)
      removed = false
      @write_mutex.synchronize do
        updated = @entries.reject(&.adapter.same?(adapter))
        removed = updated.size != @entries.size
        @entries = updated if removed
      end
      if removed
        @strategy.reset
        Log.info { "Removed replica #{adapter.name} from load balancer" }
      end
    end

    # Removes the replica registered under *key*, returning its adapter.
    def remove_key(key : String) : Grant::Adapter::Base?
      removed = nil
      @write_mutex.synchronize do
        updated = @entries.reject { |entry| entry.key == key && (removed = entry.adapter) }
        @entries = updated if removed
      end
      @strategy.reset if removed
      removed
    end

    # Get next available replica using the strategy. Allocates nothing.
    def next_replica : Grant::Adapter::Base?
      entries = @entries
      return nil if entries.empty?

      @strategy.pick(entries).try(&.adapter)
    end

    # Get next replica with fallback to any replica if all unhealthy
    def next_replica_with_fallback : Grant::Adapter::Base?
      if replica = next_replica
        return replica
      end

      entries = @entries
      return nil if entries.empty?

      # All replicas unhealthy: use the one whose last health check was newest.
      best = entries.first
      best_time = Time::UNIX_EPOCH
      entries.each do |entry|
        next unless monitor = entry.monitor
        if monitor.last_check_time > best_time
          best_time = monitor.last_check_time
          best = entry
        end
      end

      Log.warn { "All replicas unhealthy, falling back to #{best.key}" }
      best.adapter
    end

    # Get all healthy replicas
    def healthy_replicas : Array(Grant::Adapter::Base)
      @entries.select(&.healthy?).map(&.adapter)
    end

    # Check if any replicas are healthy
    def any_healthy? : Bool
      @entries.any?(&.healthy?)
    end

    # Check if all replicas are healthy
    def all_healthy? : Bool
      entries = @entries
      !entries.empty? && entries.all?(&.healthy?)
    end

    # Get replica count
    def size : Int32
      @entries.size
    end

    # Get healthy replica count
    def healthy_count : Int32
      @entries.count(&.healthy?)
    end

    # Every replica adapter, in registration order.
    def replicas : Array(Grant::Adapter::Base)
      @entries.map(&.adapter)
    end

    # Set health monitor for an adapter
    def set_health_monitor(adapter : Grant::Adapter::Base, monitor : HealthMonitor)
      @write_mutex.synchronize do
        @entries = @entries.map do |entry|
          entry.adapter.same?(adapter) ? ReplicaEntry.new(entry.adapter, entry.key, monitor, entry.weight) : entry
        end
      end
    end

    # Get load balancing strategy
    def strategy : LoadBalancingStrategy
      @strategy
    end

    # Change load balancing strategy
    def strategy=(new_strategy : LoadBalancingStrategy)
      @strategy.reset
      @strategy = new_strategy
      Log.info { "Changed load balancing strategy to #{new_strategy.class}" }
    end

    # Get status of all replicas
    def status : Array(NamedTuple(adapter: String, healthy: Bool, index: Int32))
      @entries.map_with_index do |entry, index|
        {
          adapter: entry.adapter.name,
          healthy: entry.healthy?,
          index:   index,
        }
      end
    end
  end

  # Registry for load balancers
  class LoadBalancerRegistry
    @@load_balancers = {} of String => ReplicaLoadBalancer
    @@mutex = Mutex.new

    def self.register(key : String, load_balancer : ReplicaLoadBalancer)
      @@mutex.synchronize do
        @@load_balancers[key] = load_balancer
      end
    end

    def self.get(key : String) : ReplicaLoadBalancer?
      @@mutex.synchronize { @@load_balancers[key]? }
    end

    def self.unregister(key : String)
      @@mutex.synchronize do
        @@load_balancers.delete(key)
      end
    end

    def self.clear
      @@mutex.synchronize do
        @@load_balancers.clear
      end
    end
  end
end
