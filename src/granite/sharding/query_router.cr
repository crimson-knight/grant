require "../async/sharded_executor"
require "../query/builder"

module Granite::Sharding
  # Routes queries to appropriate shards based on shard keys
  class QueryRouter(Model)
    getter shard_config : ShardConfig
    
    def initialize(@model : Model.class, @shard_config : ShardConfig)
    end
    
    # Route query to appropriate shard(s)
    def route(query : Query::Builder(Model)) : QueryExecution
      # Analyze query to determine routing
      shard_keys = extract_shard_keys(query)
      
      if shard_keys.empty?
        # No shard key in query - needs scatter-gather
        all_shards = Granite::ShardManager.shards_for_model(@model.name)
        ScatterGatherExecution(Model).new(@model, query, all_shards)
      elsif single_shard = can_route_to_single_shard?(shard_keys)
        # Can route to single shard
        SingleShardExecution(Model).new(@model, query, single_shard)
      else
        # Multiple specific shards
        targeted_shards = resolve_shards(shard_keys)
        MultiShardExecution(Model).new(@model, query, targeted_shards)
      end
    end
    
    private def extract_shard_keys(query : Query::Builder(Model)) : Array(NamedTuple(column: Symbol, value: Granite::Columns::Type))
      shard_key_columns = @shard_config.key_columns
      keys = [] of NamedTuple(column: Symbol, value: Granite::Columns::Type)
      
      # Check WHERE conditions for shard keys
      if where_fields = query.where_fields
        where_fields.each do |condition|
          # Handle union type - pattern match on the NamedTuple structure
          case condition
          when NamedTuple(join: Symbol, field: String, operator: Symbol, value: Granite::Columns::Type)
            # This is a field-based condition
            # Convert field name to symbol - Crystal doesn't have String#to_sym
            column = case condition[:field]
            when "id" then :id
            when "user_id" then :user_id
            when "tenant_id" then :tenant_id
            when "name" then :name
            when "email" then :email
            when "active" then :active
            when "region" then :region
            when "created_at" then :created_at
            else
              # For other fields, we can't create symbols dynamically
              # So we'll use a special symbol to indicate unknown
              :unknown_field
            end
            
            # Check for exact match conditions on shard keys
            if shard_key_columns.includes?(column) && condition[:operator] == :eq
              keys << {column: column, value: condition[:value]}
            end
          when NamedTuple(join: Symbol, stmt: String, value: Granite::Columns::Type)
            # Statement-based conditions are ignored for shard key extraction
          end
        end
      end
      
      keys
    end
    
    private def can_route_to_single_shard?(shard_keys : Array(NamedTuple(column: Symbol, value: Granite::Columns::Type))) : Symbol?
      return nil if shard_keys.empty?
      
      # For single shard key, resolve directly
      if shard_keys.size == 1
        key = shard_keys.first
        begin
          case key[:column]
          when :id
            @shard_config.resolver.resolve_for_keys(id: key[:value])
          when :user_id
            @shard_config.resolver.resolve_for_keys(user_id: key[:value])
          when :tenant_id
            @shard_config.resolver.resolve_for_keys(tenant_id: key[:value])
          else
            # For other columns, we can't use double splat at compile time
            # So we'll need to use the resolver's resolve method directly
            if @shard_config.resolver.is_a?(Sharding::HashResolver)
              @shard_config.resolver.as(Sharding::HashResolver).resolve_for_values([key[:value]])
            else
              nil
            end
          end
        rescue
          nil
        end
      else
        # For multiple keys, check if they all resolve to the same shard
        shards = shard_keys.map do |key|
          begin
            case key[:column]
            when :id
              @shard_config.resolver.resolve_for_keys(id: key[:value])
            when :user_id
              @shard_config.resolver.resolve_for_keys(user_id: key[:value])
            when :tenant_id
              @shard_config.resolver.resolve_for_keys(tenant_id: key[:value])
            else
              nil
            end
          rescue
            nil
          end
        end.compact
        
        # All keys must resolve to the same shard
        if shards.size == shard_keys.size && shards.uniq.size == 1
          shards.first
        else
          nil
        end
      end
    end
    
    private def resolve_shards(shard_keys : Array(NamedTuple(column: Symbol, value: Granite::Columns::Type))) : Array(Symbol)
      shards = Set(Symbol).new
      
      shard_keys.each do |key|
        begin
          shard = case key[:column]
          when :id
            @shard_config.resolver.resolve_for_keys(id: key[:value])
          when :user_id
            @shard_config.resolver.resolve_for_keys(user_id: key[:value])
          when :tenant_id
            @shard_config.resolver.resolve_for_keys(tenant_id: key[:value])
          else
            # For other columns, use resolver directly if it's a HashResolver
            if @shard_config.resolver.is_a?(Sharding::HashResolver)
              @shard_config.resolver.as(Sharding::HashResolver).resolve_for_values([key[:value]])
            else
              nil
            end
          end
          
          shards << shard if shard
        rescue
          # Skip if can't resolve
        end
      end
      
      shards.to_a
    end
  end
  
  # Base class for query execution strategies
  abstract class QueryExecution(Model)
    abstract def execute : Array(Model)
    abstract def count : Int64
    abstract def exists? : Bool
    abstract def pluck(column : String | Symbol) : Array(DB::Any)
  end
  
  # Execute query on a single shard
  class SingleShardExecution(Model) < QueryExecution(Model)
    @query : Granite::Query::Builder(Model)
    @shard : Symbol
    
    def initialize(@model : Model.class, query : Granite::Query::Builder(Model), @shard : Symbol)
      @query = query
    end
    
    def execute : Array(Model)
      Granite::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).select_without_routing
      end
    end
    
    def count : Int64
      Granite::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).count_without_routing
      end
    end
    
    def exists? : Bool
      Granite::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).exists_without_routing
      end
    end
    
    def pluck(column : String | Symbol) : Array(DB::Any)
      Granite::ShardManager.with_shard(@shard) do
        # Always use the non-routing method to avoid infinite recursion
        @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).pluck_without_routing(column)
      end
    end
  end
  
  # Execute query across all shards (scatter-gather)
  class ScatterGatherExecution(Model) < QueryExecution(Model)
    @query : Granite::Query::Builder(Model)
    @shards : Array(Symbol)
    
    def initialize(@model : Model.class, query : Granite::Query::Builder(Model), @shards : Array(Symbol))
      @query = query
    end
    
    def execute : Array(Model)
      # Use async executor for parallel execution
      results = Granite::Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        Granite::Async::AsyncResult.new do
          Granite::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).select_without_routing
          end
        end
      end
      
      # Merge and sort results
      merge_results(results.values)
    end
    
    def count : Int64
      results = Granite::Async::ShardedExecutor.execute_and_aggregate(@shards) do |shard|
        Granite::Async::AsyncResult.new do
          Granite::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).count_without_routing
          end
        end
      end
      
      results.as(Int64)
    end
    
    def exists? : Bool
      # Short-circuit on first true result
      @shards.each do |shard|
        Granite::ShardManager.with_shard(shard) do
          # Always use the non-routing method to avoid infinite recursion
          return true if @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).exists_without_routing
        end
      end
      false
    end
    
    def pluck(column : String | Symbol) : Array(DB::Any)
      results = Granite::Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        Granite::Async::AsyncResult.new do
          Granite::ShardManager.with_shard(shard) do
            # Always use the non-routing method to avoid infinite recursion
            @query.as(Granite::Sharding::ShardedQueryBuilder(Model)).pluck_without_routing(column)
          end
        end
      end
      
      # Flatten all plucked values
      results.values.flatten
    end
    
    private def merge_results(shard_results : Array(Array(Model))) : Array(Model)
      merged = shard_results.flatten
      
      # Apply any ORDER BY from original query
      if !@query.order_fields.empty?
        order_fields = @query.order_fields
        merged.sort! do |a, b|
          compare_by_order_fields(a, b, order_fields)
        end
      end
      
      # Apply LIMIT if present
      if limit = @query.limit
        merged = merged.first(limit)
      end
      
      merged
    end
    
    private def compare_by_order_fields(a : Model, b : Model, order_fields : Array(NamedTuple(field: String, direction: Granite::Query::Builder::Sort))) : Int32
      order_fields.each do |order|
        field = order[:field]
        direction = order[:direction]
        
        val_a = a.read_attribute(field)
        val_b = b.read_attribute(field)
        
        # Handle nil values
        if val_a.nil? && val_b.nil?
          next
        elsif val_a.nil?
          return direction == Granite::Query::Builder::Sort::Ascending ? -1 : 1
        elsif val_b.nil?
          return direction == Granite::Query::Builder::Sort::Ascending ? 1 : -1
        end
        
        # Compare values
        comparison = if val_a.is_a?(Number) && val_b.is_a?(Number)
          val_a <=> val_b
        elsif val_a.is_a?(String) && val_b.is_a?(String)
          val_a <=> val_b
        elsif val_a.is_a?(Time) && val_b.is_a?(Time)
          val_a <=> val_b
        else
          val_a.to_s <=> val_b.to_s
        end
        
        # The spaceship operator always returns Int32 when comparing non-nil values
        comparison = comparison.as(Int32)
        
        # Apply direction
        if direction == Granite::Query::Builder::Sort::Descending
          comparison = -comparison
        end
        
        return comparison if comparison != 0
      end
      
      0 # Equal
    end
  end
  
  # Execute query on multiple specific shards
  class MultiShardExecution(Model) < QueryExecution(Model)
    @query : Granite::Query::Builder(Model)
    @shards : Array(Symbol)
    
    def initialize(@model : Model.class, query : Granite::Query::Builder(Model), @shards : Array(Symbol))
      @query = query
    end
    
    # Delegate to ScatterGatherExecution since logic is the same
    def execute : Array(Model)
      ScatterGatherExecution(Model).new(@model, @query, @shards).execute
    end
    
    def count : Int64
      ScatterGatherExecution(Model).new(@model, @query, @shards).count
    end
    
    def exists? : Bool
      ScatterGatherExecution(Model).new(@model, @query, @shards).exists?
    end
    
    def pluck(column : String | Symbol) : Array(DB::Any)
      ScatterGatherExecution(Model).new(@model, @query, @shards).pluck(column)
    end
  end
end