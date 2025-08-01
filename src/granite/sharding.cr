module Granite::Sharding
  # Base class for all shard resolvers
  abstract class ShardResolver
    # Resolve shard for a model instance
    abstract def resolve(model : Granite::Base) : Symbol
    
    # Resolve shard for given key values (for queries)
    abstract def resolve_for_keys(**keys) : Symbol
    
    # Get all shards managed by this resolver
    abstract def all_shards : Array(Symbol)
  end
  
  # Configuration for sharding on a model
  class ShardConfig
    property key_columns : Array(Symbol)
    property resolver : ShardResolver
    
    def initialize(@key_columns : Array(Symbol), @resolver : ShardResolver)
    end
  end
  
  # Built-in hash sharding resolver
  class HashResolver < ShardResolver
    getter shard_count : Int32
    getter shard_prefix : String
    
    def initialize(@key_columns : Array(Symbol), @shard_count : Int32, @shard_prefix : String = "shard")
      @shards = (0...@shard_count).map { |i| :"#{@shard_prefix}_#{i}" }
    end
    
    def resolve(model : Granite::Base) : Symbol
      values = @key_columns.map { |col| model.read_attribute(col.to_s) }
      resolve_for_values(values)
    end
    
    def resolve_for_keys(**keys) : Symbol
      values = @key_columns.map { |col| keys[col]? || raise "Missing shard key: #{col}" }
      resolve_for_values(values)
    end
    
    def all_shards : Array(Symbol)
      @shards
    end
    
    private def resolve_for_values(values : Array) : Symbol
      # Create composite key string
      key = values.map(&.to_s).join(":")
      
      # Use hash function for even distribution
      hash_value = key.hash
      
      # Determine shard number
      shard_num = hash_value.abs % @shard_count
      
      :"#{@shard_prefix}_#{shard_num}"
    end
  end
  
  # Range-based sharding resolver
  class RangeResolver < ShardResolver
    record RangeShard, range : Range, shard : Symbol
    
    getter ranges : Array(RangeShard)
    
    def initialize(@key_column : Symbol)
      @ranges = [] of RangeShard
    end
    
    def add_range(range : Range, shard : Symbol)
      @ranges << RangeShard.new(range, shard)
      # Keep sorted for binary search
      @ranges.sort_by! { |rs| rs.range.begin }
    end
    
    def resolve(model : Granite::Base) : Symbol
      value = model.read_attribute(@key_column.to_s)
      find_shard_for_value(value)
    end
    
    def resolve_for_keys(**keys) : Symbol
      value = keys[@key_column]? || raise "Missing shard key: #{@key_column}"
      find_shard_for_value(value)
    end
    
    def all_shards : Array(Symbol)
      @ranges.map(&.shard).uniq
    end
    
    private def find_shard_for_value(value)
      # Binary search for efficiency
      range_shard = @ranges.find { |rs| rs.range.includes?(value) }
      range_shard?.try(&.shard) || raise "No shard found for value: #{value}"
    end
  end
  
  # Lookup-based sharding resolver (for geographic, etc)
  class LookupResolver < ShardResolver
    getter lookup_table : Hash(String, Symbol)
    getter default_shard : Symbol?
    
    def initialize(@key_column : Symbol, @lookup_table : Hash(String, Symbol), @default_shard : Symbol? = nil)
    end
    
    def resolve(model : Granite::Base) : Symbol
      value = model.read_attribute(@key_column.to_s).to_s
      @lookup_table[value]? || @default_shard || raise "No shard found for value: #{value}"
    end
    
    def resolve_for_keys(**keys) : Symbol
      value = keys[@key_column]?.try(&.to_s) || raise "Missing shard key: #{@key_column}"
      @lookup_table[value]? || @default_shard || raise "No shard found for value: #{value}"
    end
    
    def all_shards : Array(Symbol)
      shards = @lookup_table.values.uniq
      shards << @default_shard if @default_shard
      shards
    end
  end
  
  # Module to include in models for sharding support
  module Model
    macro included
      class_property shard_config : Granite::Sharding::ShardConfig?
      
      # Track which shard this instance came from/belongs to
      property current_shard : Symbol?
      
      # Override adapter to use sharded connection
      def self.adapter : Adapter::Base
        if config = shard_config
          # For class-level queries, we need context to determine shard
          # This would typically come from query builder context
          if shard = Thread.current[:granite_current_shard]?
            ConnectionRegistry.get_adapter(database_name, current_role, shard)
          else
            # No shard context - this is an error for sharded models
            raise "No shard context for sharded model #{name}. Use .on_shard or ensure shard key is provided."
          end
        else
          # Non-sharded model - use default behavior
          super
        end
      end
    end
    
    # DSL for configuring sharding
    macro shards_by(*columns, strategy = :hash, **options)
      {% if strategy == :hash %}
        self.shard_config = Granite::Sharding::ShardConfig.new(
          key_columns: {{columns}}.to_a.map(&.to_s.to_sym),
          resolver: Granite::Sharding::HashResolver.new(
            {{columns}}.to_a.map(&.to_s.to_sym),
            {{options[:count] || 4}},
            {{options[:prefix] || "shard"}}.to_s
          )
        )
      {% else %}
        # Other strategies would be implemented similarly
        {% raise "Unsupported sharding strategy: #{strategy}" %}
      {% end %}
    end
    
    # Query on specific shard
    def self.on_shard(shard : Symbol)
      ShardedQuery.new(self, shard)
    end
    
    # Query on all shards
    def self.on_all_shards
      MultiShardQuery.new(self)
    end
    
    # Determine shard for a model instance
    def determine_shard : Symbol
      return @current_shard if @current_shard
      
      if config = self.class.shard_config
        @current_shard = config.resolver.resolve(self)
      else
        raise "Model #{self.class.name} is not configured for sharding"
      end
    end
    
    # Ensure we're on the correct shard before operations
    macro before_save
      if self.class.shard_config
        determine_shard
        Thread.current[:granite_current_shard] = @current_shard
      end
    end
    
    macro after_save
      if self.class.shard_config
        Thread.current[:granite_current_shard] = nil
      end
    end
  end
  
  # Query builder for sharded queries
  class ShardedQuery
    def initialize(@model : Granite::Base.class, @shard : Symbol)
    end
    
    def where(**conditions)
      Thread.current[:granite_current_shard] = @shard
      result = @model.where(**conditions)
      Thread.current[:granite_current_shard] = nil
      result
    end
    
    # Implement other query methods similarly...
  end
  
  # Query builder for multi-shard queries
  class MultiShardQuery
    def initialize(@model : Granite::Base.class)
      @shards = @model.shard_config.not_nil!.resolver.all_shards
    end
    
    def count : Int64
      # Parallel count across all shards
      counts = parallel_map(@shards) do |shard|
        @model.on_shard(shard).count
      end
      counts.sum
    end
    
    # Implement other aggregation methods...
    
    private def parallel_map(shards : Array(Symbol), &block : Symbol -> T) forall T
      channel = Channel(T).new(shards.size)
      
      shards.each do |shard|
        spawn do
          result = yield shard
          channel.send(result)
        end
      end
      
      results = [] of T
      shards.size.times do
        results << channel.receive
      end
      
      results
    end
  end
end