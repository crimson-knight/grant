# Sharding Implementation Plan for Grant ORM

## Overview

This document tracks the implementation of sharding support in Grant ORM, including composite primary keys, shard resolvers, cross-shard operations, and comprehensive CI testing with multiple databases.

## Phase 1: Composite Primary Key Support (Week 1)

### 1.1 Core Implementation
- [x] Create `Granite::CompositePrimaryKey` module
- [x] Modify `Granite::Columns` to support multiple primary keys
- [x] Update `find` method to accept composite keys
- [x] Update `save` and `destroy` to work with composite keys
- [x] Add composite key validation

### 1.2 Query Support
- [x] Update WHERE clause generation for composite keys
- [x] Modify unique constraint validation
- [ ] Update associations to work with composite foreign keys

### 1.3 Tests
- [x] Unit tests for composite key CRUD operations
- [ ] Integration tests with PostgreSQL and SQLite
- [ ] Migration tests for composite key tables

**Files to create/modify:**
- `src/granite/composite_primary_key.cr`
- `src/granite/columns.cr` (modifications)
- `src/granite/querying.cr` (modifications)
- `spec/granite/composite_primary_key_spec.cr`

## Phase 2: Sharding Infrastructure (Week 2)

### 2.1 Shard Resolvers
- [ ] Implement `ShardResolver` abstract class
- [ ] Create `HashResolver` for modulo sharding
- [ ] Create `RangeResolver` for range-based sharding
- [ ] Create `LookupResolver` for custom mappings
- [ ] Create `ConsistentHashResolver` for dynamic scaling

### 2.2 Model Integration
- [ ] Add `Granite::Sharding::Model` module
- [ ] Implement `shards_by` macro
- [ ] Add `on_shard` and `on_all_shards` query methods
- [ ] Integrate shard resolution with connection management

### 2.3 Configuration
- [ ] Create shard configuration DSL
- [ ] Add shard connection mapping
- [ ] Support for dynamic shard addition/removal

**Files to create:**
- `src/granite/sharding.cr` (already started)
- `src/granite/sharding/resolvers/*.cr`
- `src/granite/sharding/model.cr`
- `src/granite/sharding/configuration.cr`

## Phase 3: Cross-Shard Operations (Week 3)

### 3.1 Query Execution
- [ ] Implement `ShardedQuery` builder
- [ ] Add `MultiShardQuery` for parallel execution
- [ ] Create scatter-gather aggregations
- [ ] Handle ordered queries across shards

### 3.2 Distributed Operations
- [ ] Implement cross-shard transactions (2PC)
- [ ] Add distributed lock management
- [ ] Handle shard failures gracefully
- [ ] Implement circuit breakers for shard health

### 3.3 Performance Optimizations
- [ ] Connection pooling per shard
- [ ] Query result caching
- [ ] Parallel query execution using fibers
- [ ] Shard resolution caching

**Files to create:**
- `src/granite/sharding/query_builder.cr`
- `src/granite/sharding/distributed_transaction.cr`
- `src/granite/sharding/connection_manager.cr`

## Phase 4: CI Testing Infrastructure (Week 4)

### 4.1 GitHub Actions Configuration

#### PostgreSQL Multi-Database Setup
```yaml
# .github/workflows/sharding_tests.yml
name: Sharding Tests

on: [push, pull_request]

jobs:
  test-postgresql-sharding:
    runs-on: ubuntu-latest
    
    services:
      # Primary database cluster
      postgres-primary-1:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: shard_0
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
      
      # Replica for primary-1
      postgres-replica-1:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: shard_0
        ports:
          - 5433:5432
          
      # Additional shards
      postgres-primary-2:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: shard_1
        ports:
          - 5434:5432
          
      postgres-replica-2:
        image: postgres:15
        env:
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: shard_1
        ports:
          - 5435:5432
          
    steps:
      - uses: actions/checkout@v3
      
      - name: Install Crystal
        uses: crystal-lang/install-crystal@v1
        
      - name: Install dependencies
        run: shards install
        
      - name: Setup PostgreSQL replication
        run: |
          # Configure primary-replica replication
          ./scripts/setup_pg_replication.sh
          
      - name: Run sharding tests
        env:
          SHARD_0_PRIMARY: postgres://postgres:postgres@localhost:5432/shard_0
          SHARD_0_REPLICA: postgres://postgres:postgres@localhost:5433/shard_0
          SHARD_1_PRIMARY: postgres://postgres:postgres@localhost:5434/shard_1
          SHARD_1_REPLICA: postgres://postgres:postgres@localhost:5435/shard_1
        run: |
          crystal spec spec/granite/sharding/**/*_spec.cr
```

### 4.2 SQLite Multi-Database Testing
- [ ] Create SQLite sharding test setup
- [ ] Implement file-based shard separation
- [ ] Test failover with backup databases
- [ ] Add performance benchmarks

### 4.3 Replica Failover Testing
- [ ] Implement health check monitoring
- [ ] Test automatic failover to replicas
- [ ] Verify write redirection on primary failure
- [ ] Test split-brain scenarios

**Files to create:**
- `.github/workflows/sharding_tests.yml`
- `scripts/setup_pg_replication.sh`
- `scripts/test_failover.sh`
- `spec/support/sharding_test_helper.cr`

## Phase 5: Integration Testing (Week 5)

### 5.1 Real-World Scenarios
- [ ] Multi-tenant application tests
- [ ] Time-series data sharding tests
- [ ] Geographic sharding tests
- [ ] High-volume write tests

### 5.2 Performance Benchmarks
- [ ] Benchmark shard resolution overhead
- [ ] Compare sharded vs non-sharded performance
- [ ] Test cross-shard query performance
- [ ] Measure failover impact

### 5.3 Chaos Testing
- [ ] Random shard failures
- [ ] Network partition simulation
- [ ] Primary/replica split scenarios
- [ ] Connection pool exhaustion

**Files to create:**
- `spec/integration/sharding_scenarios_spec.cr`
- `benchmarks/sharding_performance.cr`
- `spec/chaos/shard_failure_spec.cr`

## Phase 6: Documentation & Examples (Week 6)

### 6.1 Documentation
- [ ] Sharding guide with best practices
- [ ] Migration guide from non-sharded to sharded
- [ ] Troubleshooting guide
- [ ] Performance tuning guide

### 6.2 Examples
- [ ] Multi-tenant SaaS example
- [ ] Time-series data example
- [ ] Geographic sharding example
- [ ] E-commerce platform example

### 6.3 Tooling
- [ ] Shard rebalancing tool
- [ ] Shard health monitoring
- [ ] Query analysis tool
- [ ] Migration helper scripts

## Testing Strategy

### Unit Tests
Each component will have comprehensive unit tests covering:
- Happy path scenarios
- Edge cases
- Error conditions
- Concurrent access

### Integration Tests
- Multi-database scenarios with real PostgreSQL/SQLite
- Replica failover scenarios
- Cross-shard transactions
- Performance under load

### CI Configuration
```yaml
# Test matrix for comprehensive coverage
strategy:
  matrix:
    crystal: [1.9, 1.10, latest]
    database: [postgresql, sqlite]
    shards: [2, 4, 8]
    include:
      - database: postgresql
        replica: true
      - database: sqlite
        replica: false
```

## Success Criteria

1. **Functionality**
   - Composite primary keys work across all adapters
   - All sharding strategies implemented and tested
   - Cross-shard operations work reliably
   - Failover works seamlessly

2. **Performance**
   - Shard resolution < 1μs
   - Minimal overhead for sharded queries
   - Efficient cross-shard aggregations
   - Connection pooling prevents exhaustion

3. **Reliability**
   - 100% test coverage for sharding code
   - All CI tests passing on PostgreSQL and SQLite
   - Graceful handling of shard failures
   - No data loss during failover

4. **Usability**
   - Clear, intuitive DSL
   - Helpful error messages
   - Comprehensive documentation
   - Working examples

## Risk Mitigation

1. **Complexity**: Start with simple hash sharding, add features incrementally
2. **Performance**: Benchmark early and often
3. **Compatibility**: Test with all supported databases from day 1
4. **Reliability**: Implement comprehensive error handling and retries

## Timeline

- Week 1: Composite Primary Keys
- Week 2: Sharding Infrastructure  
- Week 3: Cross-Shard Operations
- Week 4: CI Testing Setup
- Week 5: Integration Testing
- Week 6: Documentation & Polish

Total: 6 weeks to production-ready sharding support