# Multiple Databases Implementation - Next Steps

## Summary

After thorough research of Rails' multiple database implementation and analysis of Grant's current architecture, I've prepared a comprehensive plan to implement enterprise-grade multiple database support including:

1. **Vertical Scaling**: Read/write splitting with automatic connection switching
2. **Horizontal Sharding**: Data distribution across multiple database servers
3. **Flexible Configuration**: Rails-like `connects_to` DSL
4. **Connection Pooling**: Efficient connection management
5. **Migration Support**: Database-specific migrations

## Key Improvements Over Current Implementation

### Current Limitations
- Basic reader/writer separation only
- Global connection switch timer
- No horizontal sharding
- Limited connection control
- No migration targeting

### Proposed Enhancements
- Role-based connections (writing, reading, custom)
- Per-model configuration
- Shard support with flexible resolution strategies
- Block-based connection switching
- Database-specific migrations
- Connection pooling with configurable limits
- Thread-safe connection management

## Implementation Priority

### Phase 1: Core Infrastructure (Critical)
1. **Connection Pool Implementation**
   - Thread-safe pool with checkout/checkin
   - Configurable pool sizes and timeouts
   - Lazy connection creation

2. **Connection Handler**
   - Centralized connection management
   - Specification registry
   - Pool lifecycle management

3. **Enhanced Base Class**
   - `connects_to` macro
   - `connected_to` method
   - Context management

### Phase 2: Vertical Scaling (High Priority)
1. **Automatic Role Switching**
   - Read operations use `:reading` role
   - Write operations use `:writing` role
   - Configurable delay after writes

2. **Manual Control**
   - Block-based role switching
   - Write prevention mode
   - Cross-database operations

### Phase 3: Horizontal Sharding (Medium Priority)
1. **Shard Resolution**
   - Modulo-based sharding
   - Range-based sharding
   - Custom resolution strategies

2. **Sharded Model Support**
   - Automatic shard routing
   - Cross-shard queries
   - Shard-specific operations

### Phase 4: Tooling (Lower Priority)
1. **Migration Enhancements**
   - Database-specific migrations
   - Migration generators
   - Parallel migration execution

2. **Monitoring & Debugging**
   - Connection pool statistics
   - Query routing logs
   - Performance metrics

## Technical Considerations

### Crystal-Specific Challenges

1. **Concurrency Model**
   - Crystal uses fibers, not threads
   - Need fiber-local storage for connection context
   - Careful mutex usage for shared resources

2. **Type Safety**
   - Leverage Crystal's type system
   - Compile-time validation where possible
   - Clear error messages

3. **Performance**
   - Minimize allocation in hot paths
   - Efficient connection switching
   - Lazy initialization

### Backward Compatibility Strategy

1. **Gradual Migration Path**
   - Existing `connection` macro continues working
   - Default to first connection if not specified
   - Deprecation warnings for old patterns

2. **Adapter Compatibility**
   - Maintain existing adapter interface
   - Add pooling as transparent layer
   - No changes required for custom adapters

## Example Migration Path

### Current Code
```crystal
# Current Grant code
Grant::Connections << Grant::Adapter::Pg.new(name: "primary", url: ENV["DATABASE_URL"])

class User < Grant::Base
  connection "primary"
end
```

### Migration Step 1: Add New Configuration
```crystal
# New configuration (backward compatible)
Grant::ConnectionHandler.establish_connection(
  database: "primary",
  adapter: Grant::Adapter::Pg,
  url: ENV["DATABASE_URL"],
  role: :writing
)

# Models continue to work unchanged
class User < Grant::Base
  connection "primary"  # Still works
end
```

### Migration Step 2: Adopt New Features
```crystal
# Enhanced model with read replica
class User < Grant::Base
  connects_to database: {
    writing: "primary",
    reading: "primary_replica"
  }
end

# Sharded model
class Order < Grant::Base
  include Grant::Sharding::ShardedModel
  
  connects_to shards: {
    shard1: { writing: "orders_1", reading: "orders_1_replica" },
    shard2: { writing: "orders_2", reading: "orders_2_replica" }
  }
  
  shard_by :customer_id, shards: [:shard1, :shard2]
end
```

## Risk Mitigation

1. **Testing Strategy**
   - Comprehensive test suite for each phase
   - Integration tests with real databases
   - Performance benchmarks
   - Backward compatibility tests

2. **Rollout Plan**
   - Feature flags for new functionality
   - Beta testing with real applications
   - Gradual adoption in production
   - Clear migration guides

3. **Documentation**
   - API documentation
   - Migration guides
   - Best practices
   - Common patterns

## Recommended Next Actions

1. **Review and Feedback**
   - Review the research documents
   - Identify any missing requirements
   - Prioritize features for your use case

2. **Prototype Implementation**
   - Start with connection pool
   - Implement basic `connects_to`
   - Test with simple read/write splitting

3. **Community Input**
   - Share plans with Grant community
   - Gather feedback on API design
   - Identify edge cases

4. **Incremental Development**
   - Implement Phase 1 completely
   - Release as beta feature
   - Gather real-world feedback
   - Iterate on subsequent phases

## Questions to Consider

1. **Configuration Format**: Should we support YAML configuration files like Rails?
2. **Shard Key Strategy**: What sharding strategies are most important for your use cases?
3. **Connection Switching**: Should we support automatic middleware-based switching?
4. **Migration Path**: How important is seamless migration from current implementation?
5. **Performance Requirements**: What are acceptable overhead levels for connection management?

## Conclusion

The proposed architecture provides Grant with enterprise-grade multiple database support while maintaining Crystal's performance and simplicity. The phased approach allows for incremental implementation and testing, ensuring stability throughout the process.

The design closely follows Rails' proven patterns while adapting to Crystal's unique features and constraints. This will make Grant attractive for applications requiring sophisticated database architectures while keeping the API familiar to Rails developers.