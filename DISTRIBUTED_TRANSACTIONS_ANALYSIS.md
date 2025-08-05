# Distributed Transactions & Cross-Shard Joins: Complexity Analysis

## Why These Are Incredibly Complex

### 1. Distributed Transactions

**The Challenge:**
- Traditional ACID transactions don't work across multiple database instances
- No single database can coordinate commits across shards
- Network failures can leave transactions in inconsistent states

**Complexity Points:**
```crystal
# This seems simple but is actually impossible with traditional transactions:
DB.transaction do
  user = User.find(123)      # On shard_1
  order = Order.find(456)     # On shard_2
  
  user.balance -= 100        # Update on shard_1
  order.status = "paid"      # Update on shard_2
  
  user.save!
  order.save!
end  # How do we ensure both commits succeed or both fail?
```

**Common Solutions and Their Trade-offs:**

1. **Two-Phase Commit (2PC)**
   - Complexity: Very High
   - Issues: Blocking, coordinator failures, network partitions
   - Performance: 2-3x slower than local transactions

2. **Saga Pattern**
   - Complexity: High
   - Issues: Complex compensation logic, eventual consistency
   - Example: If payment succeeds but shipping fails, must reverse payment

3. **Event Sourcing**
   - Complexity: Very High
   - Issues: Complete architecture change, complex event replay

4. **Best Practice: Avoid Distributed Transactions**
   - Design to keep related data on same shard
   - Use eventual consistency where possible
   - Accept some inconsistency risk

### 2. Cross-Shard Join Detection

**The Challenge:**
```crystal
# This innocent-looking query is actually impossible:
Order.joins(:user).where("users.country = ?", "US")
# If orders and users are on different shards, this fails
```

**Why It's Complex:**
1. **Parse-time Detection**: Need to analyze query AST before execution
2. **Dynamic Queries**: Runtime-built queries are hard to analyze
3. **Nested Joins**: Multi-level joins across multiple tables
4. **Aggregations**: COUNT, SUM across shards need special handling

**Implementation Approaches:**

```crystal
# Approach 1: Static Analysis (Medium Complexity)
class CrossShardJoinDetector
  def analyze_query(query : Query::Builder)
    tables = extract_tables(query)
    shards = tables.map { |t| determine_shard_for_table(t) }
    
    if shards.uniq.size > 1
      raise CrossShardJoinError.new(
        "Cannot join #{tables.join(', ')} - they're on different shards"
      )
    end
  end
end

# Approach 2: Runtime Detection (Lower Complexity)
class Order < Granite::Base
  belongs_to user : User
  
  # Override association to check sharding
  def user
    if self.shard != User.shard_for_id(user_id)
      raise CrossShardAssociationError.new(
        "Cannot load user #{user_id} - it's on a different shard"
      )
    end
    super
  end
end
```

## Realistic Implementation Options

### Option 1: Documentation + Best Practices (Low Effort)
```crystal
module Granite::Sharding
  module Documentation
    # Document patterns to avoid
    ANTI_PATTERNS = [
      "Cross-shard joins",
      "Distributed transactions", 
      "Foreign keys across shards"
    ]
    
    # Provide alternatives
    PATTERNS = [
      "Keep related data on same shard",
      "Use application-level joins",
      "Implement eventual consistency"
    ]
  end
end
```

### Option 2: Basic Safety Rails (Medium Effort)
```crystal
module Granite::Sharding
  # Detect obvious cross-shard issues
  module SafetyChecks
    macro belongs_to(name, **options)
      # Warn if association might cross shards
      {% if options[:shard] != @type.shard %}
        {% raise "Cross-shard association detected: #{name}" %}
      {% end %}
      
      super
    end
    
    def validate_no_cross_shard_queries
      # Basic runtime checks
      if query.includes_join? && involves_multiple_shards?
        raise "Cross-shard joins not supported"
      end
    end
  end
end
```

### Option 3: Distributed Transaction Lite (High Effort)
```crystal
module Granite::Sharding
  # Simple eventually consistent transactions
  class DistributedTransaction
    def initialize
      @operations = [] of Operation
      @compensations = [] of Compensation
    end
    
    def add_operation(shard : Symbol, &block)
      @operations << Operation.new(shard, block)
    end
    
    def add_compensation(shard : Symbol, &block)
      @compensations << Compensation.new(shard, block)
    end
    
    def execute
      completed = [] of Operation
      
      @operations.each do |op|
        begin
          ShardManager.with_shard(op.shard) do
            op.execute
          end
          completed << op
        rescue ex
          # Rollback completed operations
          rollback(completed)
          raise ex
        end
      end
    end
    
    private def rollback(completed_ops)
      # Best effort compensation
      completed_ops.reverse.each do |op|
        compensation = @compensations.find { |c| c.shard == op.shard }
        compensation.try(&.execute)
      end
    end
  end
end
```

## Recommendation

Given the complexity, I recommend:

1. **Phase 1**: Document anti-patterns and best practices
2. **Phase 2**: Add basic cross-shard detection with clear error messages
3. **Phase 3**: Provide application-level join helpers
4. **Future**: Consider saga pattern for specific use cases

**Don't Implement:**
- Full 2PC (too complex, poor performance)
- Automatic cross-shard joins (impossible to do efficiently)
- ACID guarantees across shards (fundamentally impossible)

**Do Implement:**
- Clear error messages when operations cross shards
- Documentation on sharding-friendly data models
- Helpers for common patterns (like denormalization)

## Real-World Examples

**GitHub**: Avoids distributed transactions by careful sharding
- Repositories and their issues/PRs on same shard
- User data replicated to all shards (read-only copies)

**Uber**: Uses event-driven architecture
- No distributed transactions
- Events propagate changes asynchronously
- Accepts eventual consistency

**Shopify**: Tenant-based sharding
- Each shop's data on one shard
- No cross-shop transactions needed
- Shop-to-shop operations use async events

The key insight: **Design your data model to avoid needing these features** rather than trying to implement them.