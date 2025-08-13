module Grant
  class ShardManager
    # Thread-safe storage for shard configurations
    @@shard_configs = {} of String => Sharding::ShardConfig
    @@current_shard = {} of Fiber => Symbol?
    @@mutex = Mutex.new
    
    # Register shard configuration for a model
    def self.register(model_name : String, config : Sharding::ShardConfig)
      @@mutex.synchronize do
        @@shard_configs[model_name] = config
      end
    end
    
    # Execute within shard context
    def self.with_shard(shard : Symbol, &block)
      previous = @@current_shard[Fiber.current]?
      @@current_shard[Fiber.current] = shard
      
      # Set connection context using Fiber-local storage
      # This replaces the Thread.current usage
      begin
        yield
      ensure
        @@current_shard[Fiber.current] = previous
      end
    end
    
    # Get current shard for fiber
    def self.current_shard : Symbol?
      @@current_shard[Fiber.current]?
    end
    
    # Set current shard (used internally)
    def self.set_current_shard(shard : Symbol?)
      @@current_shard[Fiber.current] = shard
    end
    
    # Resolve shard for given keys
    def self.resolve_shard(model_name : String, **keys) : Symbol
      config = @@mutex.synchronize do
        @@shard_configs[model_name]?
      end
      
      config || raise "No shard configuration for #{model_name}"
      config.resolver.resolve_for_keys(**keys)
    end
    
    # Get all shards for a model
    def self.shards_for_model(model_name : String) : Array(Symbol)
      config = @@mutex.synchronize do
        @@shard_configs[model_name]?
      end
      
      config || raise "No shard configuration for #{model_name}"
      config.resolver.all_shards
    end
    
    # Check if a model is sharded
    def self.sharded?(model_name : String) : Bool
      @@mutex.synchronize do
        @@shard_configs.has_key?(model_name)
      end
    end
    
    # Get shard configuration for a model
    def self.shard_config(model_name : String) : Sharding::ShardConfig?
      @@mutex.synchronize do
        @@shard_configs[model_name]?
      end
    end
    
    # Execute on specific shard with connection management
    def self.on_shard(shard : Symbol, database : String, role : Symbol = :primary, &block)
      with_shard(shard) do
        ConnectionRegistry.with_adapter(database, role, shard) do |adapter|
          yield adapter
        end
      end
    end
    
    # Execute on all shards for a model
    def self.on_all_shards(model_name : String, database : String, role : Symbol = :primary, &block : Symbol, Adapter::Base -> T) forall T
      shards = shards_for_model(model_name)
      results = {} of Symbol => T
      
      shards.each do |shard|
        results[shard] = on_shard(shard, database, role) do |adapter|
          yield shard, adapter
        end
      end
      
      results
    end
    
    # Clear all configurations (mainly for testing)
    def self.clear
      @@mutex.synchronize do
        @@shard_configs.clear
        @@current_shard.clear
      end
    end
    
    # Get statistics about shard distribution
    def self.shard_statistics : Hash(String, NamedTuple(model: String, shards: Array(Symbol), shard_count: Int32))
      @@mutex.synchronize do
        stats = {} of String => NamedTuple(model: String, shards: Array(Symbol), shard_count: Int32)
        
        @@shard_configs.each do |model_name, config|
          shards = config.resolver.all_shards
          stats[model_name] = {
            model: model_name,
            shards: shards,
            shard_count: shards.size
          }
        end
        
        stats
      end
    end
  end
end