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
    
    @shards : Array(Symbol)
    
    def initialize(@key_columns : Array(Symbol), @shard_count : Int32, @shard_prefix : String = "shard")
      # Crystal doesn't support dynamic symbol creation, so we need to handle known shard counts
      @shards = case @shard_count
      when 1
        [:shard_0]
      when 2
        [:shard_0, :shard_1]
      when 3
        [:shard_0, :shard_1, :shard_2]
      when 4
        [:shard_0, :shard_1, :shard_2, :shard_3]
      when 8
        [:shard_0, :shard_1, :shard_2, :shard_3, :shard_4, :shard_5, :shard_6, :shard_7]
      when 16
        [:shard_0, :shard_1, :shard_2, :shard_3, :shard_4, :shard_5, :shard_6, :shard_7,
         :shard_8, :shard_9, :shard_10, :shard_11, :shard_12, :shard_13, :shard_14, :shard_15]
      else
        raise "Unsupported shard count: #{@shard_count}. Supported counts are: 1, 2, 3, 4, 8, 16"
      end
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
    
    def resolve_for_values(values : Array) : Symbol
      # Create composite key string
      key = values.map(&.to_s).join(":")
      
      # Use hash function for even distribution
      hash_value = key.hash
      
      # Determine shard number
      shard_num = hash_value.abs % @shard_count
      
      # Return the shard symbol from our pre-defined array
      @shards[shard_num]
    end
  end
  
  # Range-based sharding resolver - TODO: implement with proper type handling
  
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
      if default = @default_shard
        shards << default
      end
      shards
    end
  end
  
  # Module to include in models for sharding support
  module Model
    macro included
      class_property sharding_config : Granite::Sharding::ShardConfig?
      
      # Track which shard this instance came from/belongs to
      property current_shard : Symbol?
      
      # Override adapter to use sharded connection
      def self.adapter : Granite::Adapter::Base
        if config = sharding_config
          # For class-level queries, we need context to determine shard
          # This would typically come from query builder context
          if shard = Granite::ShardManager.current_shard
            Granite::ConnectionRegistry.get_adapter(database_name, current_role, shard)
          else
            # No shard context - this is an error for sharded models
            raise "No shard context for sharded model #{name}. Use .on_shard or ensure shard key is provided."
          end
        else
          # Non-sharded model - use default behavior
          super
        end
      end
      
      # Query on specific shard
      def self.on_shard(shard : Symbol)
        Granite::Sharding::ShardedQuery({{@type}}).new(self, shard)
      end
      
      # Query on all shards
      def self.on_all_shards
        Granite::Sharding::MultiShardQuery({{@type}}).new(self)
      end
      
      # Execute a block on all shards
      def self.on_all_shards(&block)
        if config = sharding_config
          shards = Granite::ShardManager.shards_for_model(self.name)
          shards.each do |shard|
            Granite::ShardManager.with_shard(shard) do
              yield
            end
          end
        else
          yield # Not sharded, just execute the block
        end
      end
      
      # Iterate through all records across all shards in batches
      def self.find_each(batch_size : Int32 = 1000, &block : {{@type}} ->)
        if config = sharding_config
          shards = Granite::ShardManager.shards_for_model(self.name)
          shards.each do |shard|
            Granite::ShardManager.with_shard(shard) do
              offset = 0_i64
              loop do
                batch = limit(batch_size).offset(offset).select
                break if batch.empty?
                
                batch.each do |record|
                  record.current_shard = shard
                  yield record
                end
                
                offset += batch_size
              end
            end
          end
        else
          # Not sharded - use regular batch processing
          offset = 0_i64
          loop do
            batch = limit(batch_size).offset(offset).select
            break if batch.empty?
            
            batch.each { |record| yield record }
            offset += batch_size
          end
        end
      end
    end
    
    # DSL for configuring sharding
    macro shards_by(*columns, strategy = :hash, **options)
      {% if strategy == :hash %}
        self.sharding_config = Granite::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Granite::Sharding::HashResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:count] || 4}},
            {{options[:prefix] || "shard"}}.to_s
          )
        )
      {% elsif strategy == :range %}
        {% unless options[:ranges] %}
          {% raise "Range sharding requires :ranges option" %}
        {% end %}
        self.sharding_config = Granite::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Granite::Sharding::RangeResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:ranges]}}
          )
        )
      {% elsif strategy == :time_range %}
        {% unless options[:ranges] %}
          {% raise "Time range sharding requires :ranges option" %}
        {% end %}
        self.sharding_config = Granite::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Granite::Sharding::TimeRangeResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:ranges]}}
          )
        )
      {% elsif strategy == :geo %}
        {% unless options[:regions] %}
          {% raise "Geo sharding requires :regions option" %}
        {% end %}
        self.sharding_config = Granite::Sharding::ShardConfig.new(
          key_columns: [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
          resolver: Granite::Sharding::GeoResolver.new(
            [{% for col in columns %} {{col.id.symbolize}}, {% end %}],
            {{options[:regions]}},
            {{options[:default_shard] || :shard_global}}
          )
        )
      {% else %}
        {% raise "Unsupported sharding strategy: #{strategy}" %}
      {% end %}
      
      # Register with ShardManager
      Granite::ShardManager.register(
        {{@type.name.stringify}},
        self.sharding_config.not_nil!
      )
      
      # Override query builder to use sharded version
      def self.__builder
        # For sharded models, we can't call adapter directly since it requires shard context
        # Instead, we'll default to sqlite for now - the actual adapter will be determined
        # when the query is executed with proper shard context
        db_type = Granite::Query::Builder::DbType::Sqlite
        
        Granite::Sharding::ShardedQueryBuilder({{@type}}).new(db_type, :and, self.sharding_config)
      end
    end
    
    # Determine shard for a model instance
    def determine_shard : Symbol
      if shard = @current_shard
        return shard
      end
      
      if config = self.class.sharding_config
        @current_shard = config.resolver.resolve(self)
        @current_shard.not_nil!
      else
        raise "Model #{self.class.name} is not configured for sharding"
      end
    end
    
    # Ensure we're on the correct shard before operations
    macro before_save
      if self.class.sharding_config
        determine_shard
        Granite::ShardManager.set_current_shard(@current_shard)
      end
    end
    
    macro after_save
      if self.class.sharding_config
        Granite::ShardManager.set_current_shard(nil)
      end
    end
  end
  
  # Query builder for sharded queries - use ShardedScope instead
  # Keeping for backward compatibility but delegating to new implementation
  class ShardedQuery(Model)
    @scope : ShardedScope(Model)
    
    def initialize(@model : Model.class, @shard : Symbol)
      @scope = ShardedScope(Model).new(@model, @shard)
    end
    
    def where(**conditions)
      @scope.where(**conditions)
    end
    
    def all
      @scope.all
    end
    
    def count
      @scope.count
    end
    
    def find(id)
      @scope.find(id)
    end
  end
  
  # Query builder for multi-shard queries - use MultiShardScope instead
  # Keeping for backward compatibility but delegating to new implementation
  class MultiShardQuery(Model)
    @scope : MultiShardScope(Model)
    
    def initialize(@model : Model.class)
      @scope = MultiShardScope(Model).new(@model)
    end
    
    def count : Int64
      @scope.count
    end
    
    def where(**conditions)
      @scope.where(**conditions)
    end
    
    def all
      @scope.all
    end
  end
end

# Require additional resolvers after base classes are defined
require "./sharding/shard_manager"
require "./sharding/query_router"
require "./sharding/sharded_query_builder"
require "./sharding/range_resolver"
require "./sharding/geo_resolver"