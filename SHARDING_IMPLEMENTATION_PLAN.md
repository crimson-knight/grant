# Horizontal Sharding Implementation Plan

## Overview

This document outlines a pragmatic implementation plan for horizontal sharding in Grant, focusing on delivering value incrementally while building on existing infrastructure.

## Current State Analysis

### What We Have:
1. **Basic Shard Resolvers**: Hash, Range, and Lookup resolvers
2. **Connection Registry**: Shard-aware connection management  
3. **Async Infrastructure**: ShardedExecutor for parallel operations
4. **Model Integration**: Basic sharding DSL and shard context

### What's Missing:
1. **ShardManager**: Central coordination for shard operations
2. **Query Router**: Intelligent routing for cross-shard queries
3. **Result Merging**: Combining results from multiple shards
4. **Distributed Transactions**: Cross-shard transaction support
5. **Testing Infrastructure**: Virtual sharding for tests
6. **Production Tools**: Migration, monitoring, rebalancing

## Phased Implementation Approach

### Phase 1: Core Infrastructure (Priority: HIGH)
**Goal**: Get basic sharding working end-to-end

#### 1.1 ShardManager Implementation
```crystal
# src/granite/sharding/shard_manager.cr
module Granite
  class ShardManager
    # Centralized shard configuration and context management
  end
end
```

**Tasks**:
- [ ] Create ShardManager with shard registration
- [ ] Implement with_shard context management
- [ ] Add current_shard tracking per fiber
- [ ] Integration with ConnectionRegistry

#### 1.2 Fix Existing Integration Issues
**Tasks**:
- [ ] Update ShardedExecutor to use Grant::ShardManager
- [ ] Fix Thread.current usage (should be Fiber-aware)
- [ ] Ensure ConnectionRegistry properly routes shard connections
- [ ] Add missing error handling

#### 1.3 Basic Query Routing
```crystal
# src/granite/sharding/query_router.cr
module Granite::Sharding
  class QueryRouter
    # Route queries to appropriate shards
  end
end
```

**Tasks**:
- [ ] Implement single-shard query detection
- [ ] Add scatter-gather for queries without shard key
- [ ] Basic result merging (no sorting/limit yet)

### Phase 2: Testing Infrastructure (Priority: HIGH)
**Goal**: Enable testing without multiple physical databases

#### 2.1 Virtual Sharding
```crystal
# spec/support/virtual_sharding.cr
module Granite::Testing
  class VirtualShardAdapter
    # Simulate multiple shards in memory
  end
end
```

**Tasks**:
- [ ] Create in-memory shard simulation
- [ ] Route queries to virtual shards
- [ ] Track query execution per shard
- [ ] Add test helpers and matchers

#### 2.2 Basic Test Suite
**Tasks**:
- [ ] Test shard resolution strategies
- [ ] Test single-shard queries
- [ ] Test cross-shard queries
- [ ] Test connection routing

### Phase 3: Enhanced Query Support (Priority: MEDIUM)
**Goal**: Full query functionality across shards

#### 3.1 Advanced Result Merging
**Tasks**:
- [ ] Implement ORDER BY across shards
- [ ] Handle LIMIT/OFFSET correctly
- [ ] Aggregate functions (COUNT, SUM, etc.)
- [ ] GROUP BY support

#### 3.2 Query Optimization
**Tasks**:
- [ ] Push down filters to shards
- [ ] Optimize COUNT queries
- [ ] Implement query result caching
- [ ] Add query execution explain plan

### Phase 4: Distributed Transactions (Priority: MEDIUM)
**Goal**: Enable safe multi-shard writes

#### 4.1 Basic Transaction Support
```crystal
# src/granite/sharding/distributed_transaction.cr
module Granite::Sharding
  class DistributedTransaction
    # Coordinate transactions across shards
  end
end
```

**Tasks**:
- [ ] Implement two-phase commit
- [ ] Add transaction recovery
- [ ] Handle partial failures
- [ ] Add transaction timeout

#### 4.2 Saga Pattern (Optional)
**Tasks**:
- [ ] Implement saga orchestrator
- [ ] Add compensation support
- [ ] Create saga DSL
- [ ] Add saga monitoring

### Phase 5: Production Tools (Priority: LOW)
**Goal**: Operations and management tools

#### 5.1 Monitoring
**Tasks**:
- [ ] Shard health metrics
- [ ] Query distribution analytics
- [ ] Performance monitoring
- [ ] Alert integration

#### 5.2 Migration Tools
**Tasks**:
- [ ] Data migration between shards
- [ ] Online resharding support
- [ ] Consistency verification
- [ ] Progress tracking

## Minimum Viable Implementation

For the first iteration, focus on:

1. **ShardManager**: Central coordination
2. **Query Router**: Basic routing and merging
3. **Virtual Sharding**: Enable testing
4. **Documentation**: Clear examples

This provides a working sharding solution that can be enhanced incrementally.

## Implementation Timeline

### Week 1-2: Core Infrastructure
- Implement ShardManager
- Fix integration issues
- Basic query routing

### Week 3-4: Testing Infrastructure
- Virtual sharding adapter
- Test helpers
- Initial test suite

### Week 5-6: Query Enhancement
- Result merging
- Query optimization
- Performance testing

### Week 7-8: Documentation & Examples
- User guide
- API documentation
- Example applications

## Technical Decisions

### 1. Fiber vs Thread Context
Use Fiber-local storage instead of Thread-local:
```crystal
@@current_shard = {} of Fiber => Symbol?
```

### 2. Connection Pooling
Each shard gets its own connection pool to prevent contention.

### 3. Error Handling
Fail fast on shard resolution errors, but gracefully handle shard unavailability.

### 4. Query Language
Keep ActiveRecord-compatible syntax where possible:
```crystal
User.on_shard(:shard_1).where(active: true)
User.on_all_shards.count
```

## Testing Strategy

### 1. Unit Tests
- Shard resolver logic
- Query routing decisions
- Result merging algorithms

### 2. Integration Tests
- End-to-end query execution
- Connection management
- Transaction coordination

### 3. Performance Tests
- Parallel query execution
- Connection pool efficiency
- Large result set handling

### 4. Chaos Tests
- Shard failure scenarios
- Network partitions
- Partial failures

## Success Criteria

1. **Functional**: Can perform CRUD operations on sharded data
2. **Performant**: Parallel execution faster than sequential
3. **Reliable**: Handles failures gracefully
4. **Testable**: Can test sharding without multiple databases
5. **Documented**: Clear examples and migration guide

## Risk Mitigation

### Risk: Complexity Explosion
**Mitigation**: Start simple, add features based on user feedback

### Risk: Performance Regression
**Mitigation**: Benchmark from day one, optimize critical paths

### Risk: Breaking Changes
**Mitigation**: New APIs are additive, existing code continues to work

### Risk: Testing Complexity
**Mitigation**: Virtual sharding makes tests simple and fast

## Next Steps

1. Review and approve implementation plan
2. Set up development environment
3. Create initial ShardManager implementation
4. Build minimal working example
5. Gather feedback and iterate

## Conclusion

This plan provides a pragmatic path to implementing horizontal sharding in Grant. By focusing on core functionality first and building incrementally, we can deliver value quickly while maintaining quality and reliability.