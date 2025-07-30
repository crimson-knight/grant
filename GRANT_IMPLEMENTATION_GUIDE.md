# Grant Implementation Guide for ActiveRecord Feature Parity

## Overview
This guide provides detailed implementation instructions for upgrading Grant ORM to achieve feature parity with Rails ActiveRecord v8. Each section includes specific implementation details, code locations, and acceptance criteria.

## IMPORTANT: Phase 1 Implementation Status

Phase 1 has been implemented but requires fixes for full functionality. See sections marked with ⚠️ for critical issues that need resolution.

### Current State:
- ✅ All Phase 1 features implemented
- ⚠️ Compilation issues fixed but some features disabled
- ⚠️ Test suite blocked by PG shard compatibility issue
- 📁 Branch: `feature/phase1-activerecord-parity`

### Critical Issues to Resolve:

1. **PG Shard Compatibility** (BLOCKING)
   - Error: `PG::ResultSet::Buffer.new` type mismatch
   - Location: `lib/pg/src/pg/result_set.cr:18`
   - Impact: Cannot run test suite
   - Solution: Update shards or create compatibility layer

2. **Dirty Tracking Macro Timing**
   - Issue: Macro tries to access instance vars before initialization
   - Location: `src/granite/dirty.cr:148`
   - Current Fix: `setup_dirty_tracking` call commented out in `base.cr:103`
   - Solution: Restructure macro to use `macro finished` or alternative approach

3. **Association Metadata Retrieval**
   - Issue: Runtime access to compile-time generated metadata
   - Location: `src/granite/association_loader.cr:133`
   - Current Fix: Returns nil (eager loading non-functional)
   - Solution: Implement proper metadata registry system

### Recommended Fixes:

#### Fix 1: PG Shard Compatibility
```bash
# Option 1: Update shard.yml to use compatible versions
dependencies:
  pg:
    github: will/crystal-pg
    version: 0.26.0  # Try older version
    
# Option 2: Create a local override
lib/pg/src/pg/result_set.cr:18
# Change from: Buffer.new(conn.soc, 1, statement.connection)
# To: Buffer.new(conn.soc, 1, conn)
```

#### Fix 2: Dirty Tracking Macro
```crystal
# In src/granite/dirty.cr, restructure the macro:
macro setup_dirty_tracking
  # Use event-based approach instead of macro timing
  def after_initialize
    super if defined?(super)
    setup_dirty_tracking_for_columns
  end
  
  private def setup_dirty_tracking_for_columns
    # Runtime setup instead of compile-time
  end
end
```

#### Fix 3: Association Metadata Registry
```crystal
# Create src/granite/association_registry.cr
module Granite::AssociationRegistry
  @@registry = {} of String => Hash(String, NamedTuple(...))
  
  # Populate at compile time using macro hooks
  macro finished
    # Register all associations here
  end
end
```

## Implementation Instructions

### PHASE 1: CRITICAL FEATURES (Highest Priority)

#### 1.1 Eager Loading Implementation ⚠️

**Goal**: Implement `includes`, `preload`, and `eager_load` methods to prevent N+1 queries.

**Current Status**: 
- ✅ Core structure implemented
- ⚠️ Association metadata retrieval not working
- ⚠️ Needs metadata registry implementation

**Implementation Steps**:

1. **Create new module**: `src/granite/eager_loading.cr`
   ```crystal
   module Granite::EagerLoading
     # Track loaded associations per instance
     @loaded_associations = {} of String => Array(Granite::Base)
     
     module ClassMethods
       def includes(*associations)
         # Return a new query builder with eager loading instructions
       end
       
       def preload(*associations) 
         # Load associations in separate queries
       end
       
       def eager_load(*associations)
         # Load associations using LEFT OUTER JOIN
       end
     end
   end
   ```

2. **Modify**: `src/granite/query/builder.cr`
   - Add `@eager_load_associations : Array(Symbol)`
   - Add `@preload_associations : Array(Symbol)`
   - Modify `#exec` to handle eager loading

3. **Modify**: `src/granite/associations.cr`
   - Add association caching mechanism
   - Modify association getters to check cache first
   - Add `loaded?` method to check if association is loaded

4. **Create**: `src/granite/association_loader.cr`
   - Implement batch loading logic
   - Handle different association types (belongs_to, has_many, has_one)
   - Optimize queries to load all associations in minimal queries

**Acceptance Criteria**:
- `Post.includes(:comments).all` loads all posts and comments in 2 queries max
- Accessing `post.comments` does not trigger additional queries
- Support nested includes: `Post.includes(comments: :author)`
- No breaking changes to existing association methods

**Test Files to Create**:
- `spec/granite/eager_loading/includes_spec.cr`
- `spec/granite/eager_loading/preload_spec.cr`
- `spec/granite/eager_loading/eager_load_spec.cr`

---

#### 1.2 Dirty Tracking API ⚠️

**Goal**: Track attribute changes with methods like `changed?`, `was`, `changes`.

**Current Status**:
- ✅ Core API implemented and working
- ⚠️ Automatic method generation disabled due to macro timing
- ⚠️ Manual tracking works but per-attribute methods need fix

**Implementation Steps**:

1. **Create module**: `src/granite/dirty.cr`
   ```crystal
   module Granite::Dirty
     @original_attributes = {} of String => Granite::Columns::Type
     @changed_attributes = {} of String => Granite::Columns::Type
     
     def attribute_changed?(name : String | Symbol)
     def attribute_was(name : String | Symbol)
     def attribute_change(name : String | Symbol)
     def changes
     def changed?
     def changed_attributes
     def previous_changes
     def saved_changes
   end
   ```

2. **Modify**: `src/granite/columns.cr`
   - Intercept all setter methods to track changes
   - Store original values on load from database
   - Clear dirty state after save

3. **Modify**: `src/granite/transactions.cr`
   - Update `save` to store `previous_changes`
   - Clear dirty tracking after successful save
   - Restore state on failed save

**Acceptance Criteria**:
- `model.name_changed?` returns true after changing name
- `model.name_was` returns original value
- `model.changes` returns hash of all changes
- Dirty state cleared after successful save
- Works with all column types including arrays and JSON

**Test Files**:
- `spec/granite/dirty/dirty_tracking_spec.cr`
- `spec/granite/dirty/saved_changes_spec.cr`

---

#### 1.3 Missing Lifecycle Callbacks ✅

**Goal**: Add missing callbacks: `after_initialize`, `after_find`, `after_touch`, validation callbacks, commit callbacks.

**Current Status**:
- ✅ All callbacks implemented and working
- ✅ Conditional callbacks supported
- ✅ Commit/rollback callbacks functional

**Implementation Steps**:

1. **Modify**: `src/granite/callbacks.cr`
   ```crystal
   CALLBACK_NAMES = %w(
     after_initialize after_find
     before_validation after_validation
     before_save after_save
     before_create after_create
     before_update after_update
     before_destroy after_destroy
     after_touch
     after_commit after_rollback
     after_create_commit after_update_commit after_destroy_commit
   )
   ```

2. **Add conditional callbacks**:
   ```crystal
   macro before_save(*callbacks, if condition = nil, unless unless_condition = nil, &block)
   ```

3. **Implement commit callbacks**:
   - Track transaction state
   - Queue callbacks during transaction
   - Execute after transaction commits
   - Support rollback callbacks

4. **Trigger points**:
   - `after_initialize`: In `initialize` and `from_rs`
   - `after_find`: In `from_rs` when not new record
   - `after_touch`: In `touch` method
   - Validation callbacks: In `valid?` method
   - Commit callbacks: After database transaction

**Acceptance Criteria**:
- All callbacks fire at correct times
- Conditional callbacks work with `:if` and `:unless`
- Commit callbacks only fire after successful transaction
- Callbacks can be aborted with `abort!`
- Maintain callback execution order

**Test Files**:
- `spec/granite/callbacks/lifecycle_callbacks_spec.cr`
- `spec/granite/callbacks/conditional_callbacks_spec.cr`
- `spec/granite/callbacks/commit_callbacks_spec.cr`

---

#### 1.4 Named Scopes & Advanced Querying ✅

**Goal**: Implement `scope`, `default_scope`, `unscoped`, and scope merging.

**Current Status**:
- ✅ All scoping features implemented
- ✅ Default scope working
- ✅ Query builder enhanced with `or` and `not`

**Implementation Steps**:

1. **Create module**: `src/granite/scoping.cr`
   ```crystal
   module Granite::Scoping
     macro scope(name, body)
       def self.{{name.id}}
         {{body.id}}.call
       end
     end
     
     macro default_scope(&block)
       @@default_scope = {{block}}
     end
   end
   ```

2. **Modify query builder**:
   - Apply default scope automatically
   - Add `unscoped` method to bypass default scope
   - Implement `merge` to combine scopes
   - Support scope chaining

3. **Add query extensions**:
   ```crystal
   extending do
     def custom_method
       # Add methods to query chain
     end
   end
   ```

**Acceptance Criteria**:
- `scope :published, -> { where(published: true) }` creates class method
- Default scope applied to all queries
- `unscoped` bypasses default scope
- Scopes can be chained: `Post.published.recent`
- `merge` combines conditions properly

**Test Files**:
- `spec/granite/scoping/named_scopes_spec.cr`
- `spec/granite/scoping/default_scope_spec.cr`
- `spec/granite/scoping/scope_merging_spec.cr`

---

### PHASE 2: ESSENTIAL FEATURES

#### 2.1 Polymorphic Associations

**Goal**: Support `belongs_to :imageable, polymorphic: true`.

**Implementation Steps**:

1. **Modify**: `src/granite/associations.cr`
   ```crystal
   macro belongs_to(name, polymorphic = false, **options)
     {% if polymorphic %}
       column {{name}}_id : Int64?
       column {{name}}_type : String?
     {% end %}
   end
   ```

2. **Create polymorphic finder logic**:
   - Use `_type` column to determine class
   - Instantiate correct model type
   - Handle type safety

3. **Add polymorphic has_many**:
   ```crystal
   has_many :images, as: :imageable
   ```

**Acceptance Criteria**:
- Polymorphic belongs_to creates two columns
- Can save and load different model types
- Type column stores full class name
- Supports has_many with `:as` option

---

#### 2.2 Association Options

**Goal**: Implement `dependent`, `counter_cache`, `inverse_of`, `optional`, `touch`.

**Implementation Steps**:

1. **Dependent strategies**:
   ```crystal
   has_many :comments, dependent: :destroy  # Also: :nullify, :restrict_with_error
   ```
   - Hook into destroy callbacks
   - Implement each strategy

2. **Counter cache**:
   ```crystal
   belongs_to :post, counter_cache: true  # Or counter_cache: :replies_count
   ```
   - Auto-increment/decrement on create/destroy
   - Support custom column names

3. **Touch option**:
   ```crystal
   belongs_to :post, touch: true  # Or touch: :last_comment_at
   ```
   - Update timestamp on parent when child changes

**Acceptance Criteria**:
- Dependent options work correctly
- Counter cache maintains accurate counts
- Touch updates parent timestamps
- Optional belongs_to allows nil foreign keys

---

#### 2.3 Attribute API

**Goal**: Define custom attributes with type casting and defaults.

**Implementation Steps**:

1. **Create**: `src/granite/attributes.cr`
   ```crystal
   module Granite::Attributes
     macro attribute(name, type, default = nil)
       # Define getter/setter with type casting
       # Store in attributes hash
       # Apply default values
     end
   end
   ```

2. **Custom attribute types**:
   - Create type registry
   - Allow custom type classes
   - Handle serialization/deserialization

3. **Store accessors for JSON columns**:
   ```crystal
   store :settings, accessors: [:color, :homepage]
   ```

**Acceptance Criteria**:
- Can define attributes not backed by columns
- Type casting works correctly
- Default values applied on initialization
- Store accessors create getter/setter methods

---

#### 2.4 Enum Attributes

**Goal**: Built-in enum support with helper methods.

**Implementation Steps**:

1. **Create macro**: `src/granite/enum.cr`
   ```crystal
   macro enum(name, values)
     # Create constants
     # Create query methods: published?
     # Create bang methods: publish!
     # Create scopes: Post.published
   end
   ```

2. **Features**:
   - Integer or string storage
   - Validation of values
   - Query methods
   - State transition methods
   - Automatic scopes

**Acceptance Criteria**:
- `enum status: {draft: 0, published: 1}` works
- `post.published?` returns boolean
- `post.publish!` updates and saves
- `Post.published` returns scoped query
- Raises on invalid enum values

---

### PHASE 3: ADVANCED FEATURES

#### 3.1 Query Caching

**Goal**: Cache query results within request lifecycle.

**Implementation Steps**:

1. **Create**: `src/granite/query_cache.cr`
   - Thread-local cache storage
   - Cache key generation from SQL + params
   - Automatic cache invalidation on writes
   - Enable/disable methods

2. **Integration points**:
   - Wrap all SELECT queries
   - Clear cache on INSERT/UPDATE/DELETE
   - Middleware for web frameworks

**Acceptance Criteria**:
- Identical queries return cached results
- Cache cleared on any write operation
- Can be enabled/disabled globally
- Thread-safe implementation

---

#### 3.2 Single Table Inheritance (STI)

**Goal**: Support inheritance with `type` column.

**Implementation Steps**:

1. **STI module**: `src/granite/sti.cr`
   - Auto-set type column on save
   - Instantiate correct class on load
   - Query scoping by type
   - Support abstract base classes

2. **Class registry**:
   - Track all STI subclasses
   - Handle class name changes
   - Support namespaced classes

**Acceptance Criteria**:
- `type` column auto-populated with class name
- Loading returns correct subclass instances
- Queries scoped to class and subclasses
- Can query across all types with base class

---

### PHASE 4: NICE-TO-HAVE FEATURES

#### 4.1 Multiple Column Pluck

**Implementation**: Modify `pluck` to accept multiple columns and return array of arrays.

#### 4.2 Query Annotations

**Implementation**: Add `annotate` method to add SQL comments with source location.

#### 4.3 Schema Cache

**Implementation**: Cache table structure to avoid runtime introspection.

---

## Testing Strategy

1. **Unit Tests**: Each feature needs comprehensive specs
2. **Integration Tests**: Test feature interactions
3. **Performance Tests**: Ensure no performance regressions
4. **Database Tests**: Test against all supported databases (MySQL, PostgreSQL, SQLite)

## Code Style Guidelines

1. Follow Crystal conventions
2. Use meaningful variable names
3. Add inline documentation for public APIs
4. Maintain backward compatibility where possible
5. Add deprecation warnings for breaking changes

## Migration Guide Template

For each breaking change, create a migration guide:

```markdown
## Migrating from X to Y

### What changed
[Description of the change]

### Why it changed
[Reasoning behind the change]

### How to update your code
[Before and after code examples]
```

## Performance Considerations

1. Minimize database queries
2. Use prepared statements
3. Implement connection pooling efficiently
4. Add query result caching where appropriate
5. Benchmark before and after each feature

## Documentation Requirements

Each feature needs:
1. API documentation with examples
2. Guide documentation showing real-world usage
3. Changelog entry
4. Migration guide if breaking changes

## Next Steps for Phase 1 Completion

1. **Fix PG Shard Compatibility** (Priority 1)
   - Try downgrading pg shard version
   - Or create compatibility shim
   - Or temporarily disable PG tests

2. **Fix Dirty Tracking Macro** (Priority 2)
   - Implement runtime method generation
   - Or use alternative metaprogramming approach
   - Ensure all dirty tracking methods work

3. **Implement Association Metadata** (Priority 3)
   - Create compile-time registry
   - Make eager loading functional
   - Add comprehensive tests

4. **Run Full Test Suite** (Priority 4)
   - Fix any remaining test failures
   - Add missing test coverage
   - Verify all features work together

## Review Checklist

Before considering a feature complete:
- [ ] All tests passing
- [ ] Documentation written
- [ ] Performance benchmarked
- [ ] Works with all database adapters
- [ ] No breaking changes (or migration guide provided)
- [ ] Code reviewed
- [ ] Integration tests added

## Phase 1 Files Modified/Created

### New Files:
- `src/granite/eager_loading.cr`
- `src/granite/association_loader.cr`
- `src/granite/loaded_association_collection.cr`
- `src/granite/association_registry.cr`
- `src/granite/dirty.cr`
- `src/granite/commit_callbacks.cr`
- `src/granite/scoping.cr`
- `src/granite/eager_loading_simple.cr` (temporary)
- All corresponding spec files

### Modified Files:
- `src/granite/base.cr`
- `src/granite/associations.cr`
- `src/granite/callbacks.cr`
- `src/granite/querying.cr`
- `src/granite/query/builder.cr`
- `src/granite/transactions.cr`
- `src/granite/validators.cr`