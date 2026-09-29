require "./query_router"
require "../query/builder"

module Grant::Sharding
  # Query builder that routes queries through sharding infrastructure
  class ShardedQueryBuilder(Model) < Query::Builder(Model)
    @router : QueryRouter(Model)
    @force_shard : Symbol?
    # Set on the copy each shard runs, so its methods skip routing and run
    # the plain query against the shard that is active.
    @local_execution : Bool = false

    def initialize(db_type : DbType, boolean_operator = :and, shard_config : ShardConfig? = nil)
      super(db_type, boolean_operator)
      config = shard_config || Model.sharding_config || raise "ShardedQueryBuilder requires a shard config"
      @router = QueryRouter(Model).new(Model, config)
      @force_shard = nil
    end

    # A copy made by a chain method keeps the router and any pinned shard.
    # :nodoc:
    protected def copy_subclass_state_from(source : Query::Builder(Model)) : Nil
      return unless sharded = source.as?(ShardedQueryBuilder(Model))

      @router = sharded.@router
      @force_shard = sharded.@force_shard
      @local_execution = sharded.@local_execution
    end

    # The database type of an adapter, which picks the SQL assembler.
    def self.db_type_for(adapter : Grant::Adapter::Base) : DbType
      if adapter.postgres?
        DbType::Pg
      elsif adapter.mysql?
        DbType::Mysql
      else
        DbType::Sqlite
      end
    end

    # SQL is assembled for the adapter of the shard that is active, so a
    # PostgreSQL or MySQL shard gets its own dialect. With no shard active (a
    # bare `to_sql`, say) the first shard's adapter decides, the same one that
    # quotes the identifiers (`Model.quoting_adapter`).
    def assembler : Grant::Query::Assembler::Base(Model)
      db_type = self.class.db_type_for(Model.quoting_adapter)

      case db_type
      when DbType::Pg    then Grant::Query::Assembler::Pg(Model).new self
      when DbType::Mysql then Grant::Query::Assembler::Mysql(Model).new self
      else                    Grant::Query::Assembler::Sqlite(Model).new self
      end
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

    # A copy that runs on whichever shard is active, with no routing. The
    # scatter-gather execution calls it once per shard.
    # :nodoc:
    def local_execution : self
      copy = chain_copy
      copy.mark_local_execution
      copy
    end

    # :nodoc:
    protected def mark_local_execution : Nil
      @local_execution = true
    end

    # Runs the query on the shards it targets and merges the rows.
    def select : Array(Model)
      return select_without_routing if @local_execution

      execution.execute
    end

    # Internal method to select without routing (avoids infinite recursion).
    # Each record remembers the shard it was read from.
    def select_without_routing : Array(Model)
      records = assembler.select.run

      # Apply eager loading if any associations are specified
      all_associations = @includes_associations + @preload_associations + @eager_load_associations
      unless all_associations.empty?
        Grant::AssociationLoader.load_associations(records, all_associations)
      end

      if shard = active_shard
        records.each { |record| record.current_shard = shard }
      end

      records
    end

    # Internal method to count without routing.
    #
    # Executes directly against the current shard's adapter via the assembler
    # — no routing, hence no recursion. Normalizes the assembler's
    # grouped count results into the same shape as Query::Builder#count.
    def count_without_routing : Query::Builder::CountResult
      super
    end

    # Internal method to exists? without routing (see count_without_routing).
    def exists_without_routing : Bool
      assembler.exists?.run
    end

    # Internal method to pluck without routing.
    #
    # Runs the assembler's pluck directly against the current shard's adapter
    # — no routing, hence no recursion.
    def pluck_without_routing(column : String | Symbol) : Array(Grant::Columns::Type)
      assembler.pluck(column)
    end

    # Plucks several columns per row on the active shard, without routing.
    # The scatter-gather pluck uses it to fetch the ORDER BY values it merges on.
    # :nodoc:
    def pluck_rows_without_routing(field_names : Array(String)) : Array(Array(Grant::Columns::Type))
      field_names.each do |name|
        Grant::Query::SqlExpression.validate!(name, "pluck expression") unless Grant::Query::SqlExpression.identifier?(name)
      end

      rows_assembler = assembler
      sql = rows_assembler.pluck_sql(field_names)
      Grant::Query::Executor::Pluck(Model).new(sql, rows_assembler.numbered_parameters, field_names).run
    end

    # Override count to use routing
    def count : Query::Builder::CountResult
      return count_without_routing if @local_execution

      execution.count
    end

    # COUNT(column) across the targeted shards.
    def count(column : Symbol | String, distinct : Bool = false) : Query::Builder::CountResult
      return super if @local_execution

      name = column.to_s
      return count if (name == "all" || name == "*") && !distinct

      execution.count(column, distinct || distinct?)
    end

    # The sum over the targeted shards: the shards' sums added up.
    def sum(column : Symbol | String) : SumResult
      return super if @local_execution

      execution.sum(column)
    end

    def sum(column : Symbol | String, as type : T.class) : T forall T
      return super if @local_execution

      execution.sum(column, type)
    end

    # The average over the targeted shards, from their sums and counts.
    def avg(column : Symbol | String) : AverageResult
      return super if @local_execution

      execution.average(column)
    end

    # The smallest value over the targeted shards.
    def min(column : Symbol | String) : ExtremumResult
      return super if @local_execution

      execution.extremum("MIN", column)
    end

    # The largest value over the targeted shards.
    def max(column : Symbol | String) : ExtremumResult
      return super if @local_execution

      execution.extremum("MAX", column)
    end

    # Override exists? to use routing
    def exists? : Bool
      return exists_without_routing if @local_execution

      execution.exists?
    end

    # Override pluck to use routing
    def pluck(column : String | Symbol) : Array(Grant::Columns::Type)
      return pluck_without_routing(column) if @local_execution

      execution.pluck(column)
    end

    # Several columns per row across the targeted shards, ordered and paged
    # over the merged rows. `pick` goes through here too.
    def pluck(*fields : Symbol | String) : Array(Array(Grant::Columns::Type))
      field_names = fields.to_a.map(&.to_s)
      return pluck_rows_without_routing(field_names) if @local_execution
      return [] of Array(Grant::Columns::Type) if is_none?

      execution.pluck_rows(field_names)
    end

    # Override first to use routing
    def first : Model?
      limit(1).select.first?
    end

    # The last record: the first of the reversed order, taken across the
    # targeted shards. With no ORDER BY the primary key decides.
    def last : Model?
      reverse_order.limit(1).select.first?
    end

    # Override find to use routing with shard key optimization
    def find(id)
      # If we can determine shard from ID, route directly
      if Model.sharding_config && Model.sharding_config.not_nil!.key_columns.includes?(:id)
        shard = Grant::ShardManager.resolve_shard(Model.name, id: id)
        on_shard(shard).where(id: id).first
      else
        where(id: id).first
      end
    end

    # Override find! to use routing
    def find!(id)
      find(id) || raise Grant::RecordNotFound.new("Couldn't find #{Model.name} with id=#{id}")
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
        new_builder.order_fields << Grant::Query::OrderSupport.reverse(order)
      end
      if new_builder.order_fields.empty?
        new_builder.order_fields << {field: Model.primary_name, direction: Grant::Query::Builder::Sort::Descending}
      end

      # Preserve shard settings
      new_builder.force_shard = @force_shard

      new_builder
    end

    # Allow access to force_shard for reverse_order
    protected def force_shard=(shard : Symbol?)
      @force_shard = shard
    end

    # The shard a query runs on because the caller chose it: a
    # `ShardManager.with_shard` block or a `connected_to(shard:)` block.
    private def active_shard : Symbol?
      Grant::ShardManager.current_shard || Model.current_shard
    end

    # The shards this query visits. A shard named with `on_shard` or
    # `on_all_shards` wins, then the active shard, then the shard key.
    private def target_shards : Array(Symbol)
      if forced = @force_shard
        forced == :all ? Grant::ShardManager.shards_for_model(Model.name) : [forced]
      elsif shard = active_shard
        [shard]
      else
        @router.shards_for(self)
      end
    end

    private def execution : ScatterGatherExecution(Model)
      ScatterGatherExecution(Model).new(Model, self, target_shards)
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

    def count : Query::Builder::CountResult
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

    def count : Query::Builder::CountResult
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
