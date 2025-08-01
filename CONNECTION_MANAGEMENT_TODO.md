# Connection Management TODO

## Current Status

The connection management module provides basic functionality:
- Database name configuration
- Write operation tracking
- Connection context switching
- Write prevention
- Basic adapter access

## Missing Features

### 1. Read/Write Splitting
The original spec expected automatic switching between reader/writer connections after a delay. This requires:
- Proper adapter support for multiple connections
- ConnectionRegistry integration with reader/writer URLs
- Automatic role switching based on write timing

### 2. Replica Support
The `connection_switch_wait_period` functionality from the old API needs to be reimplemented:
- Support for `_with_replica` connection names
- Automatic switching to replica after write delay
- Configuration of read delay per model

### 3. Sharding Implementation
While the API exists, the actual sharding functionality needs:
- ConnectionRegistry support for shard-specific adapters
- Proper adapter lookup based on shard/role combination
- Integration with query methods

### 4. Connection Pool Management
The ConnectionRegistry mentions pool configuration but it's not implemented:
- Connection pool size configuration
- Pool timeout settings
- Connection health checks

## Recommendations

1. Focus on read/write splitting first as it's the most common use case
2. Implement proper ConnectionRegistry integration
3. Add adapter-level support for multiple connections
4. Create comprehensive tests for each feature

## Test Coverage Needed

- Read/write splitting with actual database connections
- Replica failover scenarios
- Shard selection logic
- Connection pool behavior
- Thread safety of connection switching