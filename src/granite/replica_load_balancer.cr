require "log"

module Granite
  # Load balancing strategies for read replicas
  abstract class LoadBalancingStrategy
    abstract def next_index(total : Int32) : Int32
    abstract def reset
  end
  
  # Round-robin load balancing
  class RoundRobinStrategy < LoadBalancingStrategy
    @current_index : Atomic(Int32) = Atomic(Int32).new(-1)
    
    def next_index(total : Int32) : Int32
      return 0 if total == 1
      @current_index.add(1) % total
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
  
  # Least connections load balancing (requires connection tracking)
  class LeastConnectionsStrategy < LoadBalancingStrategy
    @connection_counts : Hash(Int32, Atomic(Int32)) = {} of Int32 => Atomic(Int32)
    @mutex = Mutex.new
    
    def next_index(total : Int32) : Int32
      @mutex.synchronize do
        # Initialize counters if needed
        (0...total).each do |i|
          @connection_counts[i] ||= Atomic(Int32).new(0)
        end
        
        # Find index with least connections
        min_index = 0
        min_count = @connection_counts[0].get
        
        (1...total).each do |i|
          count = @connection_counts[i].get
          if count < min_count
            min_count = count
            min_index = i
          end
        end
        
        # Increment counter for selected index
        @connection_counts[min_index].add(1)
        min_index
      end
    end
    
    def release_connection(index : Int32)
      @mutex.synchronize do
        @connection_counts[index]?.try(&.sub(1))
      end
    end
    
    def reset
      @mutex.synchronize do
        @connection_counts.clear
      end
    end
  end
  
  # Manages load balancing across read replicas
  class ReplicaLoadBalancer
    Log = ::Log.for("granite.replica_load_balancer")
    
    @adapters : Array(Granite::Adapter::Base)
    @strategy : LoadBalancingStrategy
    @health_monitors : Array(HealthMonitor?)
    @mutex = Mutex.new
    
    def initialize(@adapters : Array(Granite::Adapter::Base), @strategy : LoadBalancingStrategy = RoundRobinStrategy.new)
      @health_monitors = Array(HealthMonitor?).new(@adapters.size, nil)
    end
    
    # Add a replica to the pool
    def add_replica(adapter : Granite::Adapter::Base, monitor : HealthMonitor? = nil)
      @mutex.synchronize do
        @adapters << adapter
        @health_monitors << monitor
      end
      Log.info { "Added replica #{adapter.name} to load balancer" }
    end
    
    # Remove a replica from the pool
    def remove_replica(adapter : Granite::Adapter::Base)
      @mutex.synchronize do
        if index = @adapters.index(adapter)
          @adapters.delete_at(index)
          @health_monitors.delete_at(index)
          @strategy.reset
          Log.info { "Removed replica #{adapter.name} from load balancer" }
        end
      end
    end
    
    # Get next available replica using the strategy
    def next_replica : Granite::Adapter::Base?
      @mutex.synchronize do
        return nil if @adapters.empty?
        
        healthy_indices = get_healthy_indices
        return nil if healthy_indices.empty?
        
        # If only one healthy replica, return it
        if healthy_indices.size == 1
          return @adapters[healthy_indices.first]
        end
        
        # Use strategy to select from healthy replicas
        selected_index = @strategy.next_index(healthy_indices.size)
        actual_index = healthy_indices[selected_index]
        
        adapter = @adapters[actual_index]
        Log.trace { "Selected replica #{adapter.name} (index: #{actual_index})" }
        adapter
      end
    end
    
    # Get next replica with fallback to any replica if all unhealthy
    def next_replica_with_fallback : Granite::Adapter::Base?
      # Try to get a healthy replica first
      if replica = next_replica
        return replica
      end
      
      # All replicas unhealthy, return least recently failed
      @mutex.synchronize do
        return nil if @adapters.empty?
        
        # Find replica with most recent successful health check
        best_index = 0
        best_time = Time::UNIX_EPOCH
        
        @health_monitors.each_with_index do |monitor, index|
          next unless monitor
          if monitor.last_check_time > best_time
            best_time = monitor.last_check_time
            best_index = index
          end
        end
        
        adapter = @adapters[best_index]
        Log.warn { "All replicas unhealthy, falling back to #{adapter.name}" }
        adapter
      end
    end
    
    # Get all healthy replicas
    def healthy_replicas : Array(Granite::Adapter::Base)
      @mutex.synchronize do
        get_healthy_indices.map { |i| @adapters[i] }
      end
    end
    
    # Check if any replicas are healthy
    def any_healthy? : Bool
      @mutex.synchronize do
        !get_healthy_indices.empty?
      end
    end
    
    # Check if all replicas are healthy
    def all_healthy? : Bool
      @mutex.synchronize do
        return false if @adapters.empty?
        get_healthy_indices.size == @adapters.size
      end
    end
    
    # Get replica count
    def size : Int32
      @mutex.synchronize { @adapters.size }
    end
    
    # Get healthy replica count
    def healthy_count : Int32
      @mutex.synchronize { get_healthy_indices.size }
    end
    
    # Set health monitor for an adapter
    def set_health_monitor(adapter : Granite::Adapter::Base, monitor : HealthMonitor)
      @mutex.synchronize do
        if index = @adapters.index(adapter)
          @health_monitors[index] = monitor
        end
      end
    end
    
    # Get load balancing strategy
    def strategy : LoadBalancingStrategy
      @strategy
    end
    
    # Change load balancing strategy
    def strategy=(new_strategy : LoadBalancingStrategy)
      @mutex.synchronize do
        @strategy.reset
        @strategy = new_strategy
      end
      Log.info { "Changed load balancing strategy to #{new_strategy.class}" }
    end
    
    # Get status of all replicas
    def status : Array(NamedTuple(adapter: String, healthy: Bool, index: Int32))
      @mutex.synchronize do
        @adapters.map_with_index do |adapter, index|
          monitor = @health_monitors[index]
          {
            adapter: adapter.name,
            healthy: monitor.nil? || monitor.healthy?,
            index: index
          }
        end
      end
    end
    
    private def get_healthy_indices : Array(Int32)
      indices = [] of Int32
      @adapters.each_with_index do |_, index|
        monitor = @health_monitors[index]
        # Consider healthy if no monitor or monitor reports healthy
        if monitor.nil? || monitor.healthy?
          indices << index
        end
      end
      indices
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