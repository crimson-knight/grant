---
title: "Database Scaling and Sharding"
category: "infrastructure"
subcategory: "database-management"
tags: ["scaling", "sharding", "multiple-databases", "connection-pooling", "read-replicas", "horizontal-scaling"]
complexity: "expert"
version: "1.0.0"
prerequisites: ["../core-features/models-and-columns.md", "../core-features/crud-operations.md"]
related_docs: ["transactions-and-locking.md", "monitoring-and-performance.md", "../advanced/performance/query-optimization.md"]
last_updated: "2025-01-13"
estimated_read_time: "22 minutes"
use_cases: ["high-traffic-applications", "multi-tenant-systems", "distributed-databases", "microservices"]
database_support: ["postgresql", "mysql", "sqlite"]
---

# Database Scaling and Sharding

Comprehensive guide to scaling Grant applications with multiple databases, connection management, horizontal sharding, and read replicas for high-performance distributed systems.

## Overview

As applications grow, database scaling becomes critical. This guide covers:
- Multiple database configurations
- Connection pooling and management
- Read/write splitting with replicas
- Horizontal sharding strategies
- Cross-database queries and transactions
- Performance optimization at scale

## Multiple Database Configuration

### Basic Multi-Database Setup

```crystal
# config/database.cr
module DatabaseConfig
  # Primary database
  PRIMARY_DB = DB.open(ENV["PRIMARY_DATABASE_URL"])
  
  # Analytics database
  ANALYTICS_DB = DB.open(ENV["ANALYTICS_DATABASE_URL"])
  
  # Archive database
  ARCHIVE_DB = DB.open(ENV["ARCHIVE_DATABASE_URL"])
  
  # Regional databases
  REGIONAL_DBS = {
    "us-east" => DB.open(ENV["US_EAST_DATABASE_URL"]),
    "eu-west" => DB.open(ENV["EU_WEST_DATABASE_URL"]),
    "ap-south" => DB.open(ENV["AP_SOUTH_DATABASE_URL"])
  }
end

# Model configuration
class User < Grant::Base
  # Use primary database by default
  connection DatabaseConfig::PRIMARY_DB
end

class AnalyticsEvent < Grant::Base
  # Use dedicated analytics database
  connection DatabaseConfig::ANALYTICS_DB
end

class ArchivedOrder < Grant::Base
  # Use archive database for old data
  connection DatabaseConfig::ARCHIVE_DB
end
```

### Dynamic Database Selection

```crystal
module MultiDatabase
  macro included
    # Allow dynamic database selection
    class_property current_connection : DB::Database?
    
    def self.using(connection : DB::Database)
      old_connection = @@current_connection
      @@current_connection = connection
      yield
    ensure
      @@current_connection = old_connection
    end
    
    def self.connection
      @@current_connection || super
    end
  end
end

class TenantModel < Grant::Base
  include MultiDatabase
  
  def self.for_tenant(tenant_id : String)
    db = DatabaseRouter.database_for_tenant(tenant_id)
    using(db) { yield }
  end
end

class Order < TenantModel
  column id : Int64, primary: true
  column tenant_id : String
  column total : Float64
end

# Usage
Order.for_tenant("acme-corp") do
  orders = Order.where(status: "pending").to_a
  # Queries execute on tenant-specific database
end
```

## Connection Pool Management

### Advanced Connection Pooling

```crystal
class ConnectionPool
  class Config
    property max_connections : Int32 = 25
    property min_connections : Int32 = 5
    property checkout_timeout : Time::Span = 5.seconds
    property idle_timeout : Time::Span = 300.seconds
    property reap_frequency : Time::Span = 30.seconds
    property max_lifetime : Time::Span = 1.hour
  end
  
  def initialize(@database_url : String, @config = Config.new)
    @connections = [] of DB::Connection
    @available = Channel(DB::Connection).new(@config.max_connections)
    @mutex = Mutex.new
    
    # Pre-create minimum connections
    @config.min_connections.times { create_connection }
    
    # Start reaper for idle connections
    spawn reap_idle_connections
  end
  
  def checkout : DB::Connection
    select
    when conn = @available.receive
      if conn.alive?
        conn
      else
        create_connection
      end
    when timeout(@config.checkout_timeout)
      raise "Connection pool timeout"
    end
  end
  
  def checkin(conn : DB::Connection)
    if conn.alive? && @connections.size <= @config.max_connections
      @available.send(conn)
    else
      conn.close
      @mutex.synchronize { @connections.delete(conn) }
    end
  end
  
  private def create_connection
    conn = DB.connect(@database_url)
    @mutex.synchronize { @connections << conn }
    conn
  end
  
  private def reap_idle_connections
    loop do
      sleep @config.reap_frequency
      
      @mutex.synchronize do
        now = Time.utc
        @connections.reject! do |conn|
          if conn.idle_time > @config.idle_timeout || conn.lifetime > @config.max_lifetime
            conn.close
            true
          else
            false
          end
        end
      end
    end
  end
end

# Health monitoring
class PoolMonitor
  def self.stats(pool : ConnectionPool)
    {
      total_connections: pool.connections.size,
      available_connections: pool.available_count,
      active_connections: pool.connections.size - pool.available_count,
      wait_queue_size: pool.wait_queue.size
    }
  end
  
  def self.health_check(pool : ConnectionPool) : Bool
    conn = pool.checkout
    conn.exec("SELECT 1")
    pool.checkin(conn)
    true
  rescue
    false
  end
end
```

## Read/Write Splitting

### Master-Replica Configuration

```crystal
class ReplicatedDatabase
  getter master : DB::Database
  getter replicas : Array(DB::Database)
  property read_preference : ReadPreference = ReadPreference::RoundRobin
  
  enum ReadPreference
    RoundRobin
    Random
    LeastConnections
    Primary
  end
  
  def initialize(@master, @replicas)
    @current_replica = 0
  end
  
  def read_connection : DB::Database
    case read_preference
    when .primary?
      master
    when .round_robin?
      replica = replicas[@current_replica % replicas.size]
      @current_replica += 1
      replica
    when .random?
      replicas.sample
    when .least_connections?
      replicas.min_by(&.pool.active_connections)
    else
      master
    end
  end
  
  def write_connection : DB::Database
    master
  end
  
  def transaction(&block)
    # Transactions always use master
    master.transaction do |tx|
      yield tx
    end
  end
end

# Model with read/write splitting
class SplitModel < Grant::Base
  class_property replicated_db : ReplicatedDatabase
  
  def self.connection
    if in_transaction?
      replicated_db.master
    elsif writing?
      replicated_db.write_connection
    else
      replicated_db.read_connection
    end
  end
  
  def self.writing?
    Thread.current[:writing] == true
  end
  
  def self.write_operation(&block)
    Thread.current[:writing] = true
    yield
  ensure
    Thread.current[:writing] = false
  end
end

class Product < SplitModel
  # Reads go to replicas
  def self.find(id)
    super # Uses read_connection
  end
  
  # Writes go to master
  def save
    self.class.write_operation { super }
  end
end
```

### Lag-Aware Replica Selection

```crystal
class LagAwareReplicaSelector
  struct ReplicaStatus
    property connection : DB::Database
    property lag_seconds : Float64
    property last_check : Time
    property available : Bool = true
  end
  
  def initialize(@replicas : Array(DB::Database), @max_lag : Time::Span = 5.seconds)
    @statuses = @replicas.map { |r| ReplicaStatus.new(r, 0.0, Time.utc) }
    spawn monitor_replication_lag
  end
  
  def select_replica(max_staleness : Time::Span? = nil) : DB::Database?
    threshold = max_staleness || @max_lag
    
    available_replicas = @statuses.select do |status|
      status.available && status.lag_seconds < threshold.total_seconds
    end
    
    return nil if available_replicas.empty?
    
    # Select replica with least lag
    best = available_replicas.min_by(&.lag_seconds)
    best.connection
  end
  
  private def monitor_replication_lag
    loop do
      @statuses.each do |status|
        begin
          lag = check_replication_lag(status.connection)
          status.lag_seconds = lag
          status.last_check = Time.utc
          status.available = true
        rescue
          status.available = false
        end
      end
      sleep 1.second
    end
  end
  
  private def check_replication_lag(connection : DB::Database) : Float64
    # PostgreSQL
    result = connection.scalar(<<-SQL)
      SELECT EXTRACT(EPOCH FROM (NOW() - pg_last_xact_replay_timestamp()))
    SQL
    result.as(Float64)
  rescue
    # MySQL
    result = connection.query_one("SHOW SLAVE STATUS") do |rs|
      rs.read(Int32) # Seconds_Behind_Master
    end
    result.to_f
  end
end
```

## Horizontal Sharding

### Shard Configuration

```crystal
class ShardManager
  alias ShardKey = String | Int64 | UUID
  
  struct Shard
    property name : String
    property connection : DB::Database
    property weight : Int32 = 1
    property key_range : Range(Int64, Int64)?
  end
  
  def initialize
    @shards = [] of Shard
    @hash_ring = ConsistentHashRing.new
  end
  
  def add_shard(name : String, connection : DB::Database, weight : Int32 = 1)
    shard = Shard.new(name, connection, weight)
    @shards << shard
    @hash_ring.add_node(name, weight)
  end
  
  def shard_for_key(key : ShardKey) : Shard
    shard_name = @hash_ring.get_node(key.to_s)
    @shards.find! { |s| s.name == shard_name }
  end
  
  def all_shards : Array(Shard)
    @shards
  end
end

# Consistent hashing for shard distribution
class ConsistentHashRing
  def initialize(@virtual_nodes : Int32 = 150)
    @ring = {} of UInt64 => String
    @sorted_keys = [] of UInt64
  end
  
  def add_node(node : String, weight : Int32 = 1)
    (weight * @virtual_nodes).times do |i|
      hash = hash_key("#{node}:#{i}")
      @ring[hash] = node
    end
    @sorted_keys = @ring.keys.sort
  end
  
  def get_node(key : String) : String
    return "" if @ring.empty?
    
    hash = hash_key(key)
    idx = @sorted_keys.bsearch_index { |k| k >= hash } || 0
    @ring[@sorted_keys[idx]]
  end
  
  private def hash_key(key : String) : UInt64
    Digest::MD5.hexdigest(key)[0...16].to_u64(16)
  end
end
```

### Sharded Models

```crystal
abstract class ShardedModel < Grant::Base
  class_property shard_manager : ShardManager = ShardManager.new
  
  # Must be implemented by subclasses
  abstract def shard_key : ShardManager::ShardKey
  
  def self.shard_for(key : ShardManager::ShardKey)
    shard_manager.shard_for_key(key)
  end
  
  def self.on_shard(key : ShardManager::ShardKey, &block)
    shard = shard_for(key)
    using_connection(shard.connection) { yield }
  end
  
  def self.on_all_shards(&block)
    results = [] of Array(self)
    shard_manager.all_shards.each do |shard|
      using_connection(shard.connection) do
        results << yield.to_a
      end
    end
    results.flatten
  end
  
  def save
    self.class.on_shard(shard_key) { super }
  end
  
  def delete
    self.class.on_shard(shard_key) { super }
  end
end

class ShardedOrder < ShardedModel
  column id : Int64, primary: true
  column user_id : Int64
  column total : Float64
  column created_at : Time
  
  def shard_key : ShardManager::ShardKey
    user_id
  end
  
  # Query specific shard
  def self.for_user(user_id : Int64)
    on_shard(user_id) do
      where(user_id: user_id)
    end
  end
  
  # Query across all shards
  def self.recent_orders(limit = 100)
    on_all_shards do
      where("created_at > ?", 24.hours.ago)
        .order(created_at: :desc)
        .limit(limit)
    end.sort_by(&.created_at).reverse.first(limit)
  end
end
```

### Cross-Shard Queries

```crystal
class CrossShardQueryExecutor
  def self.parallel_query(shards : Array(ShardManager::Shard), query : String, params = [] of DB::Any)
    channel = Channel(Array(DB::ResultSet)).new
    
    shards.each do |shard|
      spawn do
        result = shard.connection.query(query, params)
        channel.send(result.to_a)
      end
    end
    
    results = [] of DB::ResultSet
    shards.size.times do
      results.concat(channel.receive)
    end
    
    results
  end
  
  def self.map_reduce(shards : Array(ShardManager::Shard), 
                      map_query : String,
                      reduce_fn : Proc(Array(DB::ResultSet), T)) forall T
    # Map phase - execute on each shard
    mapped_results = parallel_query(shards, map_query)
    
    # Reduce phase - combine results
    reduce_fn.call(mapped_results)
  end
end

# Example: Count total orders across all shards
class DistributedAggregation
  def self.total_order_count
    CrossShardQueryExecutor.map_reduce(
      ShardManager.instance.all_shards,
      "SELECT COUNT(*) as count FROM orders",
      ->(results : Array(DB::ResultSet)) {
        results.sum { |r| r["count"].as(Int64) }
      }
    )
  end
  
  def self.revenue_by_region
    CrossShardQueryExecutor.map_reduce(
      ShardManager.instance.all_shards,
      <<-SQL,
        SELECT region, SUM(total) as revenue
        FROM orders
        WHERE created_at > ?
        GROUP BY region
      SQL
      ->(results : Array(DB::ResultSet)) {
        # Merge regional data from all shards
        regional_totals = Hash(String, Float64).new(0.0)
        results.each do |row|
          region = row["region"].as(String)
          revenue = row["revenue"].as(Float64)
          regional_totals[region] += revenue
        end
        regional_totals
      }
    )
  end
end
```

## Multi-Tenant Architecture

### Schema-Based Multi-Tenancy

```crystal
class TenantManager
  def self.create_tenant(tenant_id : String)
    # PostgreSQL schema creation
    Grant.connection.exec("CREATE SCHEMA IF NOT EXISTS tenant_#{tenant_id}")
    
    # Run migrations for tenant schema
    with_tenant(tenant_id) do
      MigrationRunner.run_all
    end
  end
  
  def self.with_tenant(tenant_id : String, &block)
    old_schema = current_schema
    switch_to_schema("tenant_#{tenant_id}")
    yield
  ensure
    switch_to_schema(old_schema)
  end
  
  def self.switch_to_schema(schema : String)
    # PostgreSQL
    Grant.connection.exec("SET search_path TO #{schema}")
    # MySQL
    # Grant.connection.exec("USE #{schema}")
  end
  
  def self.current_schema : String
    Grant.connection.scalar("SELECT current_schema()").as(String)
  end
end

class TenantModel < Grant::Base
  def self.for_tenant(tenant_id : String)
    TenantManager.with_tenant(tenant_id) { yield }
  end
end
```

### Database-Per-Tenant

```crystal
class DatabasePerTenantRouter
  @@connections = {} of String => DB::Database
  
  def self.connection_for(tenant_id : String) : DB::Database
    @@connections[tenant_id] ||= begin
      config = load_tenant_config(tenant_id)
      DB.open(config.database_url)
    end
  end
  
  def self.load_tenant_config(tenant_id : String)
    # Load from configuration database
    result = Grant.connection.query_one(
      "SELECT database_url FROM tenants WHERE id = ?",
      tenant_id
    ) do |rs|
      TenantConfig.new(rs.read(String))
    end
  end
  
  struct TenantConfig
    getter database_url : String
    
    def initialize(@database_url)
    end
  end
end
```

## Performance Optimization

### Connection Warmup

```crystal
class ConnectionWarmer
  def self.warmup(pool : ConnectionPool, connections : Int32 = 5)
    connections.times do
      spawn do
        conn = pool.checkout
        conn.exec("SELECT 1")
        pool.checkin(conn)
      end
    end
  end
  
  def self.warmup_with_queries(pool : ConnectionPool, queries : Array(String))
    queries.each do |query|
      spawn do
        conn = pool.checkout
        conn.exec(query)
        pool.checkin(conn)
      end
    end
  end
end

# Startup warmup
ConnectionWarmer.warmup_with_queries(DatabaseConfig::PRIMARY_DB.pool, [
  "SELECT * FROM users LIMIT 1",
  "SELECT * FROM products WHERE featured = true LIMIT 10",
  "SELECT COUNT(*) FROM orders WHERE created_at > NOW() - INTERVAL '1 day'"
])
```

### Query Routing Optimization

```crystal
class SmartQueryRouter
  def self.route(query : String, params = [] of DB::Any)
    query_type = analyze_query(query)
    
    case query_type
    when .read_heavy?
      # Route to replica with caching
      CachedReplica.instance.query(query, params)
    when .write?
      # Route to master
      Master.instance.exec(query, params)
    when .analytical?
      # Route to analytical database
      AnalyticsDB.instance.query(query, params)
    when .historical?
      # Route to archive database
      ArchiveDB.instance.query(query, params)
    else
      # Default routing
      DefaultDB.instance.query(query, params)
    end
  end
  
  private def self.analyze_query(query : String)
    normalized = query.upcase.strip
    
    if normalized.starts_with?("SELECT")
      if normalized.includes?("JOIN") && normalized.includes?("GROUP BY")
        QueryType::Analytical
      elsif normalized.includes?("WHERE created_at <")
        QueryType::Historical
      else
        QueryType::ReadHeavy
      end
    elsif normalized.starts_with?("INSERT", "UPDATE", "DELETE")
      QueryType::Write
    else
      QueryType::Other
    end
  end
  
  enum QueryType
    ReadHeavy
    Write
    Analytical
    Historical
    Other
  end
end
```

## Monitoring and Health Checks

```crystal
class DatabaseHealthMonitor
  def self.check_all_databases
    results = {} of String => HealthStatus
    
    # Check primary
    results["primary"] = check_database(DatabaseConfig::PRIMARY_DB)
    
    # Check replicas
    DatabaseConfig::REPLICAS.each_with_index do |replica, i|
      results["replica_#{i}"] = check_database(replica)
    end
    
    # Check shards
    ShardManager.instance.all_shards.each do |shard|
      results["shard_#{shard.name}"] = check_database(shard.connection)
    end
    
    results
  end
  
  def self.check_database(db : DB::Database) : HealthStatus
    start = Time.monotonic
    
    # Basic connectivity
    db.scalar("SELECT 1")
    
    # Check latency
    latency = (Time.monotonic - start).total_milliseconds
    
    # Check connection pool
    pool_stats = db.pool.stats
    
    HealthStatus.new(
      healthy: true,
      latency_ms: latency,
      active_connections: pool_stats[:active],
      available_connections: pool_stats[:available]
    )
  rescue ex
    HealthStatus.new(
      healthy: false,
      error: ex.message
    )
  end
  
  struct HealthStatus
    property healthy : Bool
    property latency_ms : Float64?
    property active_connections : Int32?
    property available_connections : Int32?
    property error : String?
    
    def initialize(@healthy, @latency_ms = nil, @active_connections = nil, 
                   @available_connections = nil, @error = nil)
    end
  end
end
```

## Testing Strategies

```crystal
describe "Database Scaling" do
  describe "Sharding" do
    it "distributes data across shards" do
      manager = ShardManager.new
      manager.add_shard("shard1", test_db_1)
      manager.add_shard("shard2", test_db_2)
      
      # Create orders for different users
      user1_orders = (1..10).map { ShardedOrder.create!(user_id: 1) }
      user2_orders = (1..10).map { ShardedOrder.create!(user_id: 2) }
      
      # Verify distribution
      shard1_count = count_on_shard(manager.shard_for_key(1))
      shard2_count = count_on_shard(manager.shard_for_key(2))
      
      (shard1_count + shard2_count).should eq(20)
    end
  end
  
  describe "Read/Write Splitting" do
    it "routes reads to replicas" do
      product = Product.find(1)  # Should hit replica
      expect_query_on(:replica)
    end
    
    it "routes writes to master" do
      product = Product.create!(name: "Test")  # Should hit master
      expect_query_on(:master)
    end
  end
end
```

## Best Practices

### 1. Monitor Connection Health
```crystal
# Regular health checks
spawn do
  loop do
    health = DatabaseHealthMonitor.check_all_databases
    health.each do |name, status|
      unless status.healthy
        Log.error { "Database #{name} is unhealthy: #{status.error}" }
        AlertSystem.notify("Database #{name} down")
      end
    end
    sleep 30.seconds
  end
end
```

### 2. Implement Graceful Degradation
```crystal
# Fallback to master if replicas fail
begin
  result = replica.query(sql)
rescue
  Log.warn { "Replica failed, falling back to master" }
  result = master.query(sql)
end
```

### 3. Use Circuit Breakers
```crystal
class CircuitBreaker
  def initialize(@threshold : Int32 = 5, @timeout : Time::Span = 60.seconds)
    @failure_count = 0
    @last_failure_time = Time.utc
    @state = :closed
  end
  
  def call(&block)
    return raise "Circuit open" if open?
    
    begin
      result = yield
      reset if @state == :half_open
      result
    rescue ex
      record_failure
      raise ex
    end
  end
end
```

## Next Steps

- [Async and Concurrency](async-concurrency.md)
- [Monitoring and Performance](monitoring-and-performance.md)
- [Transactions and Locking](transactions-and-locking.md)
- [Query Optimization](../advanced/performance/query-optimization.md)