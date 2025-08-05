require "./query_router"
require "../query/builder"

module Granite::Sharding
  # Query builder that routes queries through sharding infrastructure
  class ShardedQueryBuilder(Model) < Query::Builder(Model)
    @router : QueryRouter(Model)
    @force_shard : Symbol?
    
    def initialize(db_type : DbType, boolean_operator = :and, shard_config : ShardConfig? = nil)
      super(db_type, boolean_operator)
      config = shard_config || raise "ShardedQueryBuilder requires a shard config"
      @router = QueryRouter(Model).new(Model, config)
      @force_shard = nil
    end
    
    # Force query to run on specific shard
    def on_shard(shard : Symbol) : self
      @force_shard = shard
      self
    end
    
    # Execute query on all shards
    def on_all_shards : self
      @force_shard = :all
      self
    end
    
    # Override select to use routing
    def select : Array(Model)
      if force_shard = @force_shard
        if force_shard == :all
          # All shards requested
          all_shards = Granite::ShardManager.shards_for_model(Model.name)
          ScatterGatherExecution(Model).new(Model, self, all_shards).execute
        else
          # Single shard specified
          SingleShardExecution(Model).new(Model, self, force_shard).execute
        end
      else
        # Let router decide
        execution = @router.route(self)
        execution.execute
      end
    end
    
    # Internal method to select without routing (avoids infinite recursion)
    def select_without_routing : Array(Model)
      records = assembler.select.run
      
      # Apply eager loading if any associations are specified
      all_associations = @includes_associations + @preload_associations + @eager_load_associations
      unless all_associations.empty?
        Granite::AssociationLoader.load_associations(records, all_associations)
      end
      
      records
    end
    
    # Internal method to count without routing
    def count_without_routing : Int64
      assembler.count(query: true)
    end
    
    # Internal method to exists? without routing
    def exists_without_routing : Bool
      assembler.exists?(query: true)
    end
    
    # Internal method to pluck without routing
    def pluck_without_routing(column : String | Symbol) : Array(DB::Any)
      assembler.pluck(column)
    end
    
    # Override count to use routing
    def count : Int64
      if force_shard = @force_shard
        if force_shard == :all
          all_shards = Granite::ShardManager.shards_for_model(Model.name)
          ScatterGatherExecution(Model).new(Model, self, all_shards).count
        else
          SingleShardExecution(Model).new(Model, self, force_shard).count
        end
      else
        execution = @router.route(self)
        execution.count
      end
    end
    
    # Override exists? to use routing
    def exists? : Bool
      if force_shard = @force_shard
        if force_shard == :all
          all_shards = Granite::ShardManager.shards_for_model(Model.name)
          ScatterGatherExecution(Model).new(Model, self, all_shards).exists?
        else
          SingleShardExecution(Model).new(Model, self, force_shard).exists?
        end
      else
        execution = @router.route(self)
        execution.exists?
      end
    end
    
    # Override pluck to use routing
    def pluck(column : String | Symbol) : Array(DB::Any)
      if force_shard = @force_shard
        if force_shard == :all
          all_shards = Granite::ShardManager.shards_for_model(Model.name)
          ScatterGatherExecution(Model).new(Model, self, all_shards).pluck(column)
        else
          SingleShardExecution(Model).new(Model, self, force_shard).pluck(column)
        end
      else
        execution = @router.route(self)
        execution.pluck(column)
      end
    end
    
    # Override first to use routing
    def first : Model?
      limit(1).select.first?
    end
    
    # Override last to use routing  
    def last : Model?
      # For sharded queries, we need to get last from each shard
      # and then determine the actual last record
      if force_shard = @force_shard
        if force_shard == :all
          # Multi-shard - need custom logic
          # Get last from each shard and compare
          all_shards = Granite::ShardManager.shards_for_model(Model.name)
          results = ScatterGatherExecution(Model).new(Model, reverse_order.limit(1), all_shards).execute
          results.last?
        else
          # Single shard - standard behavior
          reverse_order.limit(1).select.first?
        end
      else
        # Let router decide
        execution = @router.route(reverse_order.limit(1))
        results = execution.execute
        results.last?
      end
    end
    
    # Override find to use routing with shard key optimization
    def find(id)
      # If we can determine shard from ID, route directly
      if Model.sharding_config && Model.sharding_config.not_nil!.key_columns.includes?(:id)
        shard = Granite::ShardManager.resolve_shard(Model.name, id: id)
        on_shard(shard).where(id: id).first
      else
        where(id: id).first
      end
    end
    
    # Override find! to use routing
    def find!(id)
      find(id) || raise Granite::RecordNotFound.new("Couldn't find #{Model.name} with id=#{id}")
    end
    
    private def reverse_order
      # Create a new builder with reversed order
      new_builder = self.class.new(@db_type, @boolean_operator)
      
      # Copy all fields
      new_builder.where_fields.concat(@where_fields)
      new_builder.group_fields.concat(@group_fields)
      new_builder.offset = @offset
      new_builder.limit = @limit
      
      # Reverse order fields
      @order_fields.each do |order|
        direction = order[:direction] == Sort::Ascending ? Sort::Descending : Sort::Ascending
        new_builder.order_fields << {field: order[:field], direction: direction}
      end
      
      # Preserve shard settings
      new_builder.force_shard = @force_shard
      
      new_builder
    end
    
    # Allow access to force_shard for reverse_order
    protected def force_shard=(shard : Symbol?)
      @force_shard = shard
    end
  end
  
  # Convenience scopes for models
  class ShardedScope(Model)
    def initialize(@model : Model.class, @shard : Symbol)
    end
    
    def all
      query_builder.on_shard(@shard)
    end
    
    def where(**conditions)
      query_builder.on_shard(@shard).where(**conditions)
    end
    
    def select
      query_builder.on_shard(@shard).select
    end
    
    def find(id)
      query_builder.on_shard(@shard).find(id)
    end
    
    def find!(id)
      query_builder.on_shard(@shard).find!(id)
    end
    
    def count
      query_builder.on_shard(@shard).count
    end
    
    def exists?(**conditions)
      if conditions.empty?
        query_builder.on_shard(@shard).exists?
      else
        query_builder.on_shard(@shard).where(**conditions).exists?
      end
    end
    
    def pluck(column)
      query_builder.on_shard(@shard).pluck(column)
    end
    
    private def query_builder
      @model.__builder.as(ShardedQueryBuilder(Model))
    end
  end
  
  class MultiShardScope(Model)
    def initialize(@model : Model.class)
    end
    
    def all
      query_builder.on_all_shards
    end
    
    def where(**conditions)
      query_builder.on_all_shards.where(**conditions)
    end
    
    def count
      query_builder.on_all_shards.count
    end
    
    def exists?(**conditions)
      if conditions.empty?
        query_builder.on_all_shards.exists?
      else
        query_builder.on_all_shards.where(**conditions).exists?
      end
    end
    
    def pluck(column)
      query_builder.on_all_shards.pluck(column)
    end
    
    private def query_builder
      @model.__builder.as(ShardedQueryBuilder(Model))
    end
  end
end