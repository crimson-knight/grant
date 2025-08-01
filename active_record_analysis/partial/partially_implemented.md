# Features Grant Has Partially Implemented

## 1. Calculations

### Current State
**What's implemented**:
- Basic `count`
- Basic `sum`
- Simple `average`
- Simple `minimum` / `maximum`

**What's missing**:
- `calculate` method for custom operations
- `ids` method
- Async versions (though Crystal would handle differently)
- Group calculations with multiple columns
- Complex aggregations with HAVING

**Rails features**:
```ruby
# Missing in Grant
User.calculate(:count, :all) 
User.group(:role).calculate(:average, :age)
User.ids # Efficient ID plucking
User.async_count # Returns promise
```

**Priority**: High - These are commonly used

## 2. Query Methods

### Current State
**What's implemented**:
- Basic where, order, limit, offset
- Simple joins
- Basic group/having

**What's missing**:
- `or` queries (advanced)
- `merge` for combining queries
- `except` / `only` for query modification
- `extending` for adding methods to relations
- `from` for subqueries
- `lock` for locking
- `readonly`
- `references` for explicit table references
- `reorder` / `reverse_order`
- `rewhere`
- `unscope` for specific attributes
- Advanced join types (left_outer_joins, etc.)

**Rails features**:
```ruby
# Missing in Grant
User.where(name: "John").or(User.where(age: 25))
User.from("(SELECT * FROM users WHERE age > 21) as users")
User.left_outer_joins(:posts)
User.lock("FOR UPDATE NOWAIT")
User.extending(SpecialMethods)
```

**Priority**: High - Core query functionality

## 3. Callbacks

### Current State
**What's implemented**:
- Basic lifecycle callbacks
- Commit callbacks

**What's missing**:
- `after_touch` callback
- Conditional callbacks (`:if`, `:unless`)
- Callback halting with `throw :abort`
- Callback ordering/priority
- `run_callbacks` for manual execution

**Rails features**:
```ruby
# Missing in Grant
after_update :notify, if: :status_changed?
after_touch :update_timestamp
around_save :log_timing
```

**Priority**: Medium - Nice to have but not critical

## 4. Transactions

### Current State
**What's implemented**:
- Basic save/create/update/destroy within implicit transactions
- Commit callbacks

**What's missing**:
- Explicit transaction blocks
- Nested transactions / savepoints
- Transaction isolation levels
- `with_lock` method
- Manual rollback control
- Transaction callbacks on explicit transactions

**Rails features**:
```ruby
# Missing in Grant
User.transaction do
  user.save!
  post.save!
end

User.transaction(isolation: :serializable) do
  # ...
end

user.with_lock do
  user.balance += 100
  user.save!
end
```

**Priority**: High - Critical for data integrity

## 5. Persistence Methods

### Current State
**What's implemented**:
- Basic save, update, destroy
- `update_column` / `update_columns`
- `toggle`
- `increment` / `decrement`

**What's missing**:
- `insert` / `insert!` / `insert_all`
- `touch_all`
- `destroy_by` / `delete_by`
- `reload` options
- `becomes` for STI
- Partial updates with `update_attribute`

**Rails features**:
```ruby
# Missing in Grant
User.insert_all([{name: "John"}, {name: "Jane"}])
User.where(active: false).touch_all
User.destroy_by(status: "inactive")
user.becomes(AdminUser)
```

**Priority**: Medium - Convenience methods

## 6. Locking

### Current State
**What's implemented**:
- None

**What's missing**:
- Optimistic locking with `lock_version`
- Pessimistic locking with `lock!` / `with_lock`
- Row-level locking options
- Table-level locking

**Rails features**:
```ruby
# Missing in Grant
class User < ActiveRecord::Base
  # Optimistic locking
  self.locking_column = :lock_version
end

# Pessimistic locking
user.lock! # SELECT ... FOR UPDATE
user.with_lock do
  # Critical section
end
```

**Priority**: High - Important for concurrent access

## 7. Counter Cache

### Current State
**What's implemented**:
- Basic counter cache with `counter_cache: true`

**What's missing**:
- `reset_counters`
- `update_counters`
- `increment_counter` / `decrement_counter`
- Custom counter cache columns
- Counter cache for polymorphic associations

**Rails features**:
```ruby
# Missing in Grant
User.reset_counters(user.id, :posts)
User.update_counters(user.id, posts_count: 1, comments_count: -2)
User.increment_counter(:views_count, post.id)
```

**Priority**: Medium - Current implementation works for basic use

## 8. Reflection

### Current State
**What's implemented**:
- Basic model introspection

**What's missing**:
- Association reflection API
- Attribute reflection
- `reflect_on_association`
- `reflect_on_all_associations`
- Reflection metadata

**Rails features**:
```ruby
# Missing in Grant
User.reflect_on_association(:posts)
User.reflect_on_all_associations(:has_many)
User.attribute_types
```

**Priority**: Low - Mostly for metaprogramming

## 9. Read/Write Splitting

### Current State
**What's implemented**:
- Basic reader/writer separation
- Time-based switching after writes

**What's missing**:
- Role-based connection switching
- Manual connection control
- Middleware for automatic switching
- Multiple read replicas
- Custom switching strategies

**Priority**: High - Covered in multiple database research

## 10. Query Cache

### Current State
**What's implemented**:
- None

**What's missing**:
- Query result caching
- Cache invalidation
- Cache key generation
- Enable/disable controls

**Rails features**:
```ruby
# Missing in Grant
User.cache do
  User.find(1) # Cached
  User.find(1) # From cache
end
User.uncached do
  # Bypass cache
end
```

**Priority**: Medium - Performance optimization

## 11. Validation Contexts

### Current State
**What's implemented**:
- Basic validations

**What's missing**:
- Validation contexts
- Conditional validations
- Custom validation methods
- `validates_with` for validator classes
- Validation options (`:on`, `:if`, `:unless`)

**Rails features**:
```ruby
# Missing in Grant
validates :email, presence: true, on: :create
validates :age, numericality: true, if: :adult?
valid?(:custom_context)
```

**Priority**: Medium - Advanced validation scenarios

## 12. Batches

### Current State
**What's implemented**:
- `find_each`
- `find_in_batches`

**What's missing**:
- `in_batches` for relation batches
- Batch options (start, finish, error_on_ignore)
- Cursor-based iteration

**Rails features**:
```ruby
# Missing in Grant
User.in_batches(of: 1000) do |batch|
  batch.update_all(status: "processed")
end
```

**Priority**: Low - Current implementation sufficient

## Summary

Grant has made good progress on many features but most need additional work to reach full parity. The highest priorities for completion are:

1. **Transactions** - Critical for data integrity
2. **Locking** - Important for concurrent access
3. **Advanced Query Methods** - Core functionality
4. **Calculations** - Commonly used features

Many partially implemented features work well enough for common use cases but lack the full flexibility and options that Rails provides. The good news is that the foundations are solid and extending them should be straightforward.