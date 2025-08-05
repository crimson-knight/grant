# Sharding Patterns Research

## Overview

This document explores various sharding patterns, their trade-offs, and implementation considerations for Grant's horizontal sharding feature.

## Sharding Strategies Comparison

### 1. Hash-Based Sharding

**How it works**: Uses a hash function on the shard key to determine shard placement.

**Pros**:
- Even data distribution
- Simple to implement
- Predictable performance
- No hotspots if hash function is good

**Cons**:
- Difficult to add/remove shards (requires rehashing)
- Range queries require hitting all shards
- No locality of related data

**Best for**: 
- Uniform access patterns
- When shard count is relatively stable
- Key-value workloads

**Implementation in Grant**:
```crystal
# Uses modulo of hash for shard selection
shard_id = key.hash.abs % shard_count
```

### 2. Range-Based Sharding

**How it works**: Divides data into contiguous ranges based on shard key values.

**Pros**:
- Efficient range queries
- Easy to understand and reason about
- Can optimize for access patterns
- Natural ordering preserved

**Cons**:
- Can create hotspots
- Requires careful range planning
- Uneven data distribution possible
- Range management overhead

**Best for**:
- Time-series data
- Sequential IDs
- When range queries are common

**Implementation considerations**:
- Dynamic range splitting for growing shards
- Range merge for shrinking data
- Monitoring for hotspots

### 3. Geographic/Location-Based Sharding

**How it works**: Routes data based on geographic attributes.

**Pros**:
- Data locality (reduces latency)
- Compliance with data residency laws
- Natural disaster isolation
- Predictable routing

**Cons**:
- Uneven distribution (some regions larger)
- Cross-region queries expensive
- Complex failover scenarios
- Regional growth differences

**Best for**:
- Multi-national applications
- Compliance requirements
- Latency-sensitive applications

### 4. Directory-Based Sharding

**How it works**: Maintains a lookup table mapping keys to shards.

**Pros**:
- Maximum flexibility
- Can handle any distribution
- Easy to rebalance
- Supports complex routing rules

**Cons**:
- Lookup table becomes bottleneck
- Additional storage overhead
- Consistency challenges
- Extra network hop

**Best for**:
- Irregular access patterns
- Legacy system migration
- When other strategies don't fit

### 5. Consistent Hashing

**How it works**: Maps both shards and keys to points on a ring.

**Pros**:
- Minimal data movement when adding/removing shards
- No central directory
- Graceful scaling
- Good load distribution

**Cons**:
- More complex than simple hashing
- Virtual nodes add overhead
- Range queries still expensive
- Replication complexity

**Best for**:
- Dynamic environments
- Frequent shard additions/removals
- Distributed caches

## Cross-Shard Query Patterns

### 1. Scatter-Gather

**Pattern**: Send query to all shards, merge results.

```crystal
results = shards.map do |shard|
  shard.execute_query(query)
end.flatten.sort
```

**Optimization strategies**:
- Parallel execution
- Early termination for LIMIT queries
- Push down aggregations
- Result streaming

### 2. Targeted Multi-Shard

**Pattern**: Route to specific subset of shards based on query analysis.

```crystal
affected_shards = analyze_query_shards(query)
results = affected_shards.map { |s| s.execute(query) }
```

**Benefits**:
- Better than full scatter-gather
- Reduces network traffic
- Lower latency

### 3. Shard-Key Routing

**Pattern**: Extract shard key from query, route to single shard.

```crystal
if shard_key = extract_shard_key(query)
  shard = resolve_shard(shard_key)
  return shard.execute(query)
end
```

**Requirements**:
- Query must include shard key
- Query analyzer to extract keys
- Clear error when shard key missing

## Distributed Transaction Patterns

### 1. Two-Phase Commit (2PC)

**Phases**:
1. Prepare: All participants vote
2. Commit/Abort: Coordinator decides based on votes

**Pros**:
- Strong consistency
- ACID guarantees
- Well-understood

**Cons**:
- Blocking protocol
- Coordinator is SPOF
- Performance overhead
- Doesn't handle network partitions well

### 2. Saga Pattern

**How it works**: Series of local transactions with compensating actions.

```crystal
saga.add_step(
  forward: -> { debit_account(100) },
  compensate: -> { credit_account(100) }
)
```

**Pros**:
- No distributed locks
- Better availability
- Can handle long-running transactions
- More scalable

**Cons**:
- Eventual consistency only
- Complex compensation logic
- Harder to reason about
- Business logic leaks into infrastructure

### 3. Event Sourcing with CQRS

**Pattern**: Store events, project to read models per shard.

**Pros**:
- Natural sharding boundary (aggregates)
- Event log for audit
- Can replay to fix issues
- Temporal queries

**Cons**:
- Complex to implement
- Eventually consistent
- Storage overhead
- Requires mindset shift

## Rebalancing Strategies

### 1. Stop-the-World Migration

**Process**:
1. Stop writes
2. Copy data to new shards
3. Update routing
4. Resume writes

**Pros**: Simple, consistent
**Cons**: Downtime required

### 2. Online Migration with Dual Writes

**Process**:
1. Start dual writes (old + new)
2. Backfill historical data
3. Verify consistency
4. Cut over reads
5. Stop writing to old

**Pros**: No downtime
**Cons**: Complex, temporary 2x writes

### 3. Consistent Hashing with Virtual Nodes

**Process**:
1. Add new shard to ring
2. Virtual nodes automatically rebalance
3. Background migration of affected ranges

**Pros**: Automatic, minimal data movement
**Cons**: Requires consistent hashing

### 4. Progressive Migration

**Process**:
1. Migrate in small batches
2. Update routing table per batch
3. Verify each batch
4. Continue until complete

**Pros**: Can pause/resume, less risky
**Cons**: Long migration time, complex state management

## Testing Strategies

### 1. Virtual Sharding

Create in-memory shard simulation:

```crystal
class VirtualShardCluster
  def initialize(@shard_count : Int32)
    @shards = Hash(Symbol, MemoryDatabase).new
  end
  
  def execute_on_shard(shard_id, query)
    @shards[shard_id].execute(query)
  end
end
```

### 2. Chaos Testing

Simulate failures:
- Shard unavailability
- Network partitions
- Slow shards
- Data corruption

### 3. Load Testing

Test patterns:
- Uniform distribution
- Hotspot scenarios
- Cross-shard transactions
- Rebalancing under load

### 4. Correctness Testing

Verify:
- No data loss during rebalancing
- Consistent reads after writes
- Transaction atomicity
- Query result accuracy

## Performance Optimization Techniques

### 1. Connection Pooling

Per-shard connection pools with:
- Dynamic sizing
- Health checks
- Circuit breakers
- Graceful degradation

### 2. Query Result Caching

Cache strategies:
- Shard-local caching
- Distributed cache layer
- Query result caching
- Invalidation patterns

### 3. Batch Operations

Optimize bulk operations:
```crystal
# Group by shard before insert
records_by_shard = records.group_by { |r| resolve_shard(r) }
records_by_shard.each do |shard, batch|
  shard.bulk_insert(batch)
end
```

### 4. Read Replicas per Shard

Benefits:
- Read scaling per shard
- Geo-distributed reads
- Failure isolation
- Load balancing

## Common Pitfalls and Solutions

### 1. Cross-Shard Joins

**Problem**: Joins across shards are expensive.

**Solutions**:
- Denormalize data
- Use application-level joins
- Broadcast small tables
- Co-locate related data

### 2. Global Secondary Indexes

**Problem**: Indexes not partitioned with data.

**Solutions**:
- Maintain separate index shards
- Use eventually consistent indexes
- Query routing based on index
- Index covering queries

### 3. Unique Constraints

**Problem**: Ensuring uniqueness across shards.

**Solutions**:
- UUID primary keys
- Shard-specific prefixes
- Central ID service
- Eventual consistency checks

### 4. Transactions Across Shards

**Problem**: No ACID across shards.

**Solutions**:
- Saga pattern
- 2PC where necessary
- Design to avoid cross-shard transactions
- Event sourcing

## Monitoring and Observability

### Key Metrics

1. **Shard Health**:
   - Availability per shard
   - Latency percentiles
   - Error rates
   - Connection pool saturation

2. **Data Distribution**:
   - Records per shard
   - Storage per shard
   - Growth rate per shard
   - Hot key detection

3. **Query Patterns**:
   - Single vs multi-shard queries
   - Cross-shard transaction rate
   - Cache hit rates
   - Query latency by type

4. **Rebalancing**:
   - Migration progress
   - Data movement rate
   - Consistency check results
   - Impact on production traffic

### Alerting Rules

1. **Shard Imbalance**: Alert when any shard >30% larger than average
2. **Failed Transactions**: Alert on distributed transaction failures
3. **Query Latency**: Alert on p99 latency degradation
4. **Shard Unavailable**: Alert immediately on shard downtime

## Decision Matrix

| Criteria | Hash | Range | Geographic | Directory | Consistent Hash |
|----------|------|-------|------------|-----------|-----------------|
| Even Distribution | ★★★★★ | ★★☆☆☆ | ★★☆☆☆ | ★★★★☆ | ★★★★☆ |
| Range Query Efficiency | ★☆☆☆☆ | ★★★★★ | ★★☆☆☆ | ★★☆☆☆ | ★☆☆☆☆ |
| Rebalancing Ease | ★☆☆☆☆ | ★★★☆☆ | ★★☆☆☆ | ★★★★★ | ★★★★☆ |
| Implementation Complexity | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★☆☆☆ | ★★☆☆☆ |
| Scalability | ★★★☆☆ | ★★★☆☆ | ★★★★☆ | ★★★★☆ | ★★★★★ |

## Recommendations for Grant

1. **Start with Hash Sharding**: Simplest to implement and understand
2. **Add Range Sharding**: For time-series and sequential data
3. **Implement Geographic**: For compliance and latency requirements
4. **Virtual Sharding for Tests**: Enable testing without multiple databases
5. **Saga over 2PC**: Better availability and scalability
6. **Progressive Migration**: Safer for production systems
7. **Monitor Everything**: Comprehensive metrics from day one

## Conclusion

Successful sharding requires careful consideration of data access patterns, consistency requirements, and operational complexity. Grant should provide flexible primitives that allow users to choose the right strategy for their use case while providing sensible defaults and safety guardrails.