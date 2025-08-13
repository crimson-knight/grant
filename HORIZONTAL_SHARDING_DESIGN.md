# Horizontal Sharding Design Document

## Executive Summary

This document outlines the design for implementing comprehensive horizontal sharding support in Grant. The implementation builds on existing infrastructure while adding critical components for production-ready sharding: cross-shard queries, distributed transactions, shard management, and rebalancing tools.

## Goals

1. **Type-Safe Shard Resolution**: Leverage Crystal's type system to prevent shard routing errors
2. **Transparent Sharding**: Minimize code changes when adding sharding to existing models
3. **High Performance**: Utilize async features for parallel cross-shard operations
4. **Flexible Strategies**: Support multiple sharding strategies (hash, range, lookup, custom)
5. **Production Ready**: Include monitoring, migration, and rebalancing tools
6. **Testable**: Enable sharding tests without multiple physical databases

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   Application Layer                  │
├─────────────────────────────────────────────────────┤
│                  Grant ORM Models                    │
├─────────────────────────────────────────────────────┤
│              Sharding Middleware Layer               │
│  ┌───────────┐ ┌────────────┐ ┌────────────────┐   │
│  │   Query    │ │Transaction │ │     Shard      │   │
│  │  Router    │ │Coordinator │ │    Manager     │   │
│  └───────────┘ └────────────┘ └────────────────┘   │
├─────────────────────────────────────────────────────┤
│              Connection Management                   │
│  ┌───────────┐ ┌────────────┐ ┌────────────────┐   │
│  │Connection │ │   Health   │ │  Load Balancer │   │
│  │ Registry  │ │  Monitor   │ │   (Replicas)   │   │
│  └───────────┘ └────────────┘ └────────────────┘   │
├─────────────────────────────────────────────────────┤
│            Physical Database Shards                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │ Shard 0  │ │ Shard 1  │ │ Shard N  │ ...       │
│  └──────────┘ └──────────┘ └──────────┘           │
└─────────────────────────────────────────────────────┘
```

## Core Components

### 1. Enhanced Shard Configuration

```crystal
module Grant::Sharding
  # Enhanced configuration with more options
  class ShardConfig
    property strategy : ShardingStrategy
    property key_columns : Array(Symbol)
    property resolver : ShardResolver
    property cross_shard_joins : Bool = false
    property auto_migrate : Bool = false
    property read_preference : ReadPreference = ReadPreference::Primary
    
    enum ReadPreference
      Primary
      Secondary
      Nearest
    end
  end
  
  # Type-safe sharding strategies
  enum ShardingStrategy
    Hash
    Range
    Geographic
    Custom
    Composite  # Multiple strategies combined
  end
end
```

### 2. Shard Manager (Missing Component)

```crystal
module Grant
  class ShardManager
    @@shard_configs = {} of String => Sharding::ShardConfig
    @@current_shard = {} of Fiber => Symbol?
    
    # Register shard configuration for a model
    def self.register(model_name : String, config : Sharding::ShardConfig)
      @@shard_configs[model_name] = config
    end
    
    # Execute within shard context
    def self.with_shard(shard : Symbol, &block)
      previous = @@current_shard[Fiber.current]?
      @@current_shard[Fiber.current] = shard
      
      # Set connection context
      Thread.current[:grant_current_shard] = shard
      
      yield
    ensure
      @@current_shard[Fiber.current] = previous
      Thread.current[:grant_current_shard] = previous
    end
    
    # Get current shard for fiber
    def self.current_shard : Symbol?
      @@current_shard[Fiber.current]?
    end
    
    # Resolve shard for given keys
    def self.resolve_shard(model_name : String, **keys) : Symbol
      config = @@shard_configs[model_name]? || 
        raise "No shard configuration for #{model_name}"
      
      config.resolver.resolve_for_keys(**keys)
    end
    
    # Get all shards for a model
    def self.shards_for_model(model_name : String) : Array(Symbol)
      config = @@shard_configs[model_name]? || 
        raise "No shard configuration for #{model_name}"
      
      config.resolver.all_shards
    end
  end
end
```

### 3. Query Router (New Component)

```crystal
module Grant::Sharding
  class QueryRouter
    def initialize(@model : Grant::Base.class)
      @shard_config = @model.shard_config.not_nil!
    end
    
    # Route query to appropriate shard(s)
    def route(query : Query::Builder) : QueryExecution
      # Analyze query to determine routing
      shard_keys = extract_shard_keys(query)
      
      if shard_keys.empty?
        # No shard key in query - needs scatter-gather
        ScatterGatherExecution.new(@model, query, all_shards)
      elsif single_shard = can_route_to_single_shard?(shard_keys)
        # Can route to single shard
        SingleShardExecution.new(@model, query, single_shard)
      else
        # Multiple specific shards
        targeted_shards = resolve_shards(shard_keys)
        MultiShardExecution.new(@model, query, targeted_shards)
      end
    end
    
    private def extract_shard_keys(query) : Array(NamedTuple)
      # Extract shard key values from WHERE conditions
      shard_key_columns = @shard_config.key_columns
      
      query.where_fields.compact_map do |field|
        if shard_key_columns.includes?(field[:field].to_sym)
          {column: field[:field], value: field[:value]}
        end
      end
    end
    
    private def can_route_to_single_shard?(shard_keys) : Symbol?
      # Check if all shard keys point to same shard
      return nil if shard_keys.empty?
      
      shards = shard_keys.map do |key|
        @shard_config.resolver.resolve_for_keys(**{key[:column] => key[:value]})
      end.uniq
      
      shards.size == 1 ? shards.first : nil
    end
  end
  
  # Execution strategies
  abstract class QueryExecution
    abstract def execute : ResultSet
    abstract def count : Int64
    abstract def exists? : Bool
  end
  
  class SingleShardExecution < QueryExecution
    def initialize(@model : Grant::Base.class, @query : Query::Builder, @shard : Symbol)
    end
    
    def execute : ResultSet
      ShardManager.with_shard(@shard) do
        @query.select.execute
      end
    end
  end
  
  class ScatterGatherExecution < QueryExecution
    def initialize(@model : Grant::Base.class, @query : Query::Builder, @shards : Array(Symbol))
    end
    
    def execute : ResultSet
      # Use async executor for parallel execution
      results = Async::ShardedExecutor.execute_and_wait(@shards) do |shard|
        AsyncResult.new do
          ShardManager.with_shard(shard) do
            @query.select.to_a
          end
        end
      end
      
      # Merge and sort results
      merge_results(results.values)
    end
    
    def count : Int64
      results = Async::ShardedExecutor.execute_and_aggregate(@shards) do |shard|
        AsyncResult.new do
          ShardManager.with_shard(shard) do
            @query.count
          end
        end
      end
      
      results.as(Int64)
    end
    
    private def merge_results(shard_results : Array(Array(T))) : ResultSet forall T
      merged = shard_results.flatten
      
      # Apply any ORDER BY from original query
      if order_fields = @query.order_fields.presence
        merged.sort! do |a, b|
          # Complex sorting logic based on order_fields
          compare_by_order_fields(a, b, order_fields)
        end
      end
      
      # Apply LIMIT if present
      if limit = @query.limit
        merged = merged.first(limit)
      end
      
      ResultSet.new(merged)
    end
  end
end
```

### 4. Distributed Transaction Coordinator

```crystal
module Grant::Sharding
  class DistributedTransaction
    enum State
      Preparing
      Prepared
      Committing
      Committed
      Aborting
      Aborted
    end
    
    class Participant
      property shard : Symbol
      property state : State = State::Preparing
      property transaction_id : String
      property connection : DB::Connection?
      
      def initialize(@shard, @transaction_id)
      end
    end
    
    def initialize
      @transaction_id = UUID.random.to_s
      @participants = {} of Symbol => Participant
      @state = State::Preparing
      @mutex = Mutex.new
    end
    
    # Two-phase commit implementation
    def execute(&block)
      begin
        # Phase 1: Prepare
        prepare_phase
        
        # Execute business logic
        result = yield self
        
        # Phase 2: Commit
        commit_phase
        
        result
      rescue ex
        # Rollback on any error
        abort_phase
        raise ex
      end
    end
    
    # Add operation to transaction
    def on_shard(shard : Symbol, &block)
      @mutex.synchronize do
        participant = @participants[shard] ||= Participant.new(shard, @transaction_id)
        
        ShardManager.with_shard(shard) do
          ConnectionRegistry.with_adapter(shard.to_s, :primary, shard) do |adapter|
            adapter.open do |conn|
              participant.connection = conn
              
              # Start transaction on this shard
              conn.exec("BEGIN")
              
              # Execute operations
              yield
              
              # Mark as prepared (in real 2PC, would prepare here)
              participant.state = State::Prepared
            end
          end
        end
      end
    end
    
    private def prepare_phase
      @participants.each do |shard, participant|
        # In true 2PC, would send PREPARE command
        # For now, we assume success if no errors
        participant.state = State::Prepared
      end
      @state = State::Prepared
    end
    
    private def commit_phase
      @state = State::Committing
      
      # Commit all participants
      commit_promises = @participants.map do |shard, participant|
        Async::Promise.new do
          ShardManager.with_shard(shard) do
            if conn = participant.connection
              conn.exec("COMMIT")
              participant.state = State::Committed
            end
          end
        end
      end
      
      # Wait for all commits
      commit_promises.each(&.wait)
      @state = State::Committed
    end
    
    private def abort_phase
      @state = State::Aborting
      
      # Rollback all participants
      @participants.each do |shard, participant|
        if conn = participant.connection
          begin
            conn.exec("ROLLBACK")
          rescue
            # Log rollback failure
          end
          participant.state = State::Aborted
        end
      end
      
      @state = State::Aborted
    end
  end
  
  # Saga pattern for eventual consistency
  class Saga
    record Step,
      name : String,
      forward : Proc(Nil),
      compensate : Proc(Nil)
    
    def initialize
      @steps = [] of Step
      @executed_steps = [] of Step
    end
    
    def add_step(name : String, forward : Proc(Nil), compensate : Proc(Nil))
      @steps << Step.new(name, forward, compensate)
    end
    
    def execute
      @steps.each do |step|
        begin
          step.forward.call
          @executed_steps << step
        rescue ex
          # Compensate in reverse order
          compensate_all
          raise ex
        end
      end
    end
    
    private def compensate_all
      @executed_steps.reverse_each do |step|
        begin
          step.compensate.call
        rescue ex
          # Log compensation failure
          Log.error { "Failed to compensate step #{step.name}: #{ex.message}" }
        end
      end
    end
  end
end
```

### 5. Shard Migration and Rebalancing

```crystal
module Grant::Sharding
  class ShardMigrator
    def initialize(@model : Grant::Base.class)
      @shard_config = @model.shard_config.not_nil!
    end
    
    # Migrate data between shards
    def migrate_range(
      from_shard : Symbol,
      to_shard : Symbol,
      key_range : Range,
      batch_size : Int32 = 1000
    )
      migrated_count = 0
      
      # Use cursor-based pagination
      last_id = nil
      
      loop do
        # Fetch batch from source shard
        records = fetch_batch(from_shard, key_range, last_id, batch_size)
        break if records.empty?
        
        # Insert into target shard
        insert_batch(to_shard, records)
        
        # Update progress
        migrated_count += records.size
        last_id = records.last.id
        
        # Verify consistency
        verify_batch(records, from_shard, to_shard)
        
        Log.info { "Migrated #{migrated_count} records" }
      end
      
      migrated_count
    end
    
    # Online resharding with minimal downtime
    def reshard(new_shard_count : Int32)
      resharding_plan = create_resharding_plan(new_shard_count)
      
      # Phase 1: Dual writes
      enable_dual_writes(resharding_plan)
      
      # Phase 2: Migrate existing data
      resharding_plan.migrations.each do |migration|
        migrate_with_verification(migration)
      end
      
      # Phase 3: Verify consistency
      verify_all_shards(resharding_plan)
      
      # Phase 4: Cut over to new sharding
      cutover_to_new_shards(resharding_plan)
      
      # Phase 5: Cleanup old shards
      cleanup_old_shards(resharding_plan)
    end
    
    private def create_resharding_plan(new_shard_count : Int32) : ReshardingPlan
      current_shards = @shard_config.resolver.all_shards
      
      # Calculate data movement required
      plan = ReshardingPlan.new(
        old_shards: current_shards,
        new_shards: generate_new_shards(new_shard_count),
        migrations: calculate_migrations(current_shards, new_shard_count)
      )
      
      plan
    end
  end
  
  # Shard health monitoring
  class ShardMonitor
    def initialize(@model : Grant::Base.class)
      @metrics = {} of Symbol => ShardMetrics
    end
    
    def collect_metrics
      shards = ShardManager.shards_for_model(@model.name)
      
      shards.each do |shard|
        metrics = ShardMetrics.new(
          shard: shard,
          record_count: count_records(shard),
          size_bytes: estimate_size(shard),
          query_latency: measure_latency(shard),
          error_rate: calculate_error_rate(shard)
        )
        
        @metrics[shard] = metrics
      end
    end
    
    def rebalancing_needed? : Bool
      return false if @metrics.size < 2
      
      sizes = @metrics.values.map(&.size_bytes)
      avg_size = sizes.sum / sizes.size
      max_deviation = sizes.max - avg_size
      
      # Rebalance if any shard is >20% larger than average
      max_deviation > avg_size * 0.2
    end
  end
end
```

### 6. Enhanced Model Integration

```crystal
module Grant::Sharding::Model
  macro sharded(strategy = :hash, on = nil, count = nil, **options)
    {% if strategy == :hash %}
      {% if on.nil? %}
        {% raise "Must specify shard key columns with 'on:'" %}
      {% end %}
      
      {% key_columns = on.is_a?(ArrayLiteral) ? on : [on] %}
      
      # Configure sharding
      class_property shard_config : Grant::Sharding::ShardConfig?
      
      # Register with ShardManager
      Grant::ShardManager.register(
        {{@type.name.stringify}},
        Grant::Sharding::ShardConfig.new(
          strategy: Grant::Sharding::ShardingStrategy::Hash,
          key_columns: {{key_columns}}.map(&.to_s.to_sym),
          resolver: Grant::Sharding::HashResolver.new(
            {{key_columns}}.map(&.to_s.to_sym),
            {{count || 4}},
            {{options[:prefix]?.try(&.to_s) || @type.name.underscore}}
          ),
          cross_shard_joins: {{options[:cross_shard_joins]? || false}},
          auto_migrate: {{options[:auto_migrate]? || false}}
        )
      )
      
      # Override query builder to use router
      def self.__builder
        router = Grant::Sharding::QueryRouter.new(self)
        ShardedQueryBuilder.new(router, super)
      end
      
    {% elsif strategy == :range %}
      # Range sharding configuration
      {% key_column = on || raise "Must specify shard key column for range sharding" %}
      
      resolver = Grant::Sharding::RangeResolver.new({{key_column}}.to_sym)
      
      # Add ranges from options
      {% if ranges = options[:ranges] %}
        {% for range_def in ranges %}
          resolver.add_range({{range_def[:range]}}, {{range_def[:shard]}})
        {% end %}
      {% end %}
      
      Grant::ShardManager.register(
        {{@type.name.stringify}},
        Grant::Sharding::ShardConfig.new(
          strategy: Grant::Sharding::ShardingStrategy::Range,
          key_columns: [{{key_column}}.to_sym],
          resolver: resolver
        )
      )
      
    {% elsif strategy == :geographic %}
      # Geographic sharding
      {% key_column = on || :region %}
      {% mapping = options[:mapping] || raise "Must provide region mapping" %}
      
      resolver = Grant::Sharding::LookupResolver.new(
        {{key_column}}.to_sym,
        {{mapping}},
        {{options[:default_shard]?}}
      )
      
      Grant::ShardManager.register(
        {{@type.name.stringify}},
        Grant::Sharding::ShardConfig.new(
          strategy: Grant::Sharding::ShardingStrategy::Geographic,
          key_columns: [{{key_column}}.to_sym],
          resolver: resolver
        )
      )
      
    {% else %}
      {% raise "Unknown sharding strategy: #{strategy}" %}
    {% end %}
    
    # Instance methods
    def shard : Symbol
      determine_shard
    end
    
    # Class methods for shard operations
    def self.on_shard(shard : Symbol)
      ShardedScope.new(self, shard)
    end
    
    def self.on_all_shards
      MultiShardScope.new(self)
    end
    
    # Distributed transaction support
    def self.distributed_transaction(&block)
      tx = Grant::Sharding::DistributedTransaction.new
      tx.execute(&block)
    end
  end
  
  # Sharded query builder
  class ShardedQueryBuilder < Query::Builder
    def initialize(@router : QueryRouter, @inner : Query::Builder)
    end
    
    def select
      execution = @router.route(@inner)
      execution.execute
    end
    
    def count
      execution = @router.route(@inner)
      execution.count
    end
    
    # Delegate other methods to inner builder
    macro method_missing(call)
      @inner.{{call}}
      self
    end
  end
end
```

## Testing Strategy

### 1. Virtual Sharding for Tests

```crystal
module Grant::Testing
  class VirtualShardAdapter < Grant::Adapter::Base
    @@shards = {} of Symbol => MockDatabase
    
    def initialize(@shard : Symbol, @base_adapter : Grant::Adapter::Base)
      @@shards[@shard] ||= MockDatabase.new
    end
    
    # Route queries to appropriate mock database
    def select(query, &block)
      @@shards[@shard].execute_query(query, &block)
    end
    
    # Simulate network latency
    def with_simulated_latency(ms : Int32)
      sleep(ms.milliseconds)
      yield
    end
  end
  
  # Test helpers
  module ShardingHelpers
    def with_virtual_shards(count : Int32, &block)
      # Set up virtual shards
      original_adapter = User.adapter
      
      begin
        setup_virtual_shards(count)
        yield
      ensure
        restore_adapter(original_adapter)
      end
    end
    
    def assert_queries_on_shard(shard : Symbol, &block)
      query_log = track_shard_queries do
        yield
      end
      
      query_log.should contain_queries_for_shard(shard)
    end
  end
end
```

### 2. Test Scenarios

```crystal
describe "Horizontal Sharding" do
  it "routes queries to correct shard based on shard key" do
    with_virtual_shards(4) do
      user = User.create!(id: 123, name: "Test", region: "us-east")
      
      assert_queries_on_shard(:shard_2) do
        found = User.find(123)
        found.should eq(user)
      end
    end
  end
  
  it "performs scatter-gather for queries without shard key" do
    with_virtual_shards(4) do
      # Create users on different shards
      users = create_distributed_users(10)
      
      # Query without shard key should hit all shards
      query_log = track_shard_queries do
        results = User.where(active: true).to_a
        results.size.should eq(10)
      end
      
      query_log.shards_accessed.should eq([:shard_0, :shard_1, :shard_2, :shard_3])
    end
  end
  
  it "handles distributed transactions" do
    with_virtual_shards(4) do
      User.distributed_transaction do |tx|
        tx.on_shard(:shard_0) do
          User.create!(id: 1, name: "User 1")
        end
        
        tx.on_shard(:shard_1) do
          User.create!(id: 2, name: "User 2")
        end
      end
      
      # Both should be committed
      User.on_shard(:shard_0).find(1).should_not be_nil
      User.on_shard(:shard_1).find(2).should_not be_nil
    end
  end
  
  it "rolls back distributed transaction on error" do
    with_virtual_shards(4) do
      expect_raises(Exception) do
        User.distributed_transaction do |tx|
          tx.on_shard(:shard_0) do
            User.create!(id: 1, name: "User 1")
          end
          
          tx.on_shard(:shard_1) do
            raise "Simulated error"
          end
        end
      end
      
      # Nothing should be committed
      User.on_shard(:shard_0).find?(1).should be_nil
    end
  end
end
```

## Implementation Plan

### Phase 1: Core Infrastructure (Week 1-2)
1. Implement ShardManager
2. Create QueryRouter with single-shard routing
3. Add virtual sharding for tests
4. Basic integration tests

### Phase 2: Cross-Shard Queries (Week 3-4)
1. Implement scatter-gather execution
2. Add result merging and sorting
3. Optimize with async execution
4. Performance benchmarks

### Phase 3: Distributed Transactions (Week 5-6)
1. Two-phase commit coordinator
2. Saga pattern for eventual consistency
3. Transaction recovery mechanisms
4. Comprehensive transaction tests

### Phase 4: Management Tools (Week 7-8)
1. Shard migration tools
2. Online resharding support
3. Monitoring and metrics
4. Admin UI/CLI tools

### Phase 5: Production Hardening (Week 9-10)
1. Failure handling and retries
2. Circuit breakers for shard health
3. Comprehensive documentation
4. Performance optimization

## Configuration Examples

### Basic Hash Sharding
```crystal
class User < Grant::Base
  include Grant::Sharding::Model
  
  sharded strategy: :hash,
          on: :id,
          count: 8,
          prefix: "user_shard"
end
```

### Geographic Sharding
```crystal
class Order < Grant::Base
  include Grant::Sharding::Model
  
  sharded strategy: :geographic,
          on: :region,
          mapping: {
            "us-east" => :shard_us_east,
            "us-west" => :shard_us_west,
            "eu" => :shard_eu,
            "asia" => :shard_asia
          },
          default_shard: :shard_us_east
end
```

### Range-Based Sharding
```crystal
class Event < Grant::Base
  include Grant::Sharding::Model
  
  sharded strategy: :range,
          on: :created_at,
          ranges: [
            {range: Time.utc(2024, 1)..Time.utc(2024, 7), shard: :shard_2024_h1},
            {range: Time.utc(2024, 7)..Time.utc(2025, 1), shard: :shard_2024_h2},
            {range: Time.utc(2025, 1)..Time.utc(2025, 7), shard: :shard_2025_h1}
          ]
end
```

### Composite Sharding
```crystal
class Transaction < Grant::Base
  include Grant::Sharding::Model
  
  sharded strategy: :composite,
          primary: {strategy: :hash, on: :account_id, count: 4},
          secondary: {strategy: :range, on: :created_at}
end
```

## Performance Considerations

1. **Connection Pooling**: Each shard has its own connection pool
2. **Query Caching**: Cache shard resolution for repeated queries
3. **Batch Operations**: Optimize bulk inserts to group by shard
4. **Parallel Execution**: Use fiber-based concurrency for cross-shard queries
5. **Result Streaming**: Stream large result sets instead of loading all in memory

## Monitoring and Observability

1. **Metrics to Track**:
   - Query distribution across shards
   - Cross-shard query frequency
   - Shard size and growth rate
   - Transaction success/failure rates
   - Rebalancing operations

2. **Health Checks**:
   - Per-shard availability
   - Replication lag (for read replicas)
   - Connection pool saturation
   - Query latency by shard

3. **Alerting**:
   - Shard imbalance (>20% deviation)
   - Failed distributed transactions
   - Shard unavailability
   - Migration failures

## Security Considerations

1. **Data Isolation**: Ensure queries can't accidentally cross shard boundaries
2. **Access Control**: Per-shard access permissions
3. **Encryption**: Support per-shard encryption keys
4. **Audit Logging**: Track cross-shard operations

## Future Enhancements

1. **Auto-scaling**: Automatically add shards based on load
2. **Smart Routing**: ML-based query routing optimization
3. **Global Secondary Indexes**: Cross-shard indexes for non-sharded queries
4. **Multi-region Support**: Geographic replication and routing
5. **Shard Pools**: Dynamic shard allocation from pools

## Conclusion

This design provides a comprehensive, type-safe, and performant horizontal sharding solution for Grant. By leveraging Crystal's type system and async capabilities, we can provide a superior developer experience while maintaining the performance required for large-scale applications.