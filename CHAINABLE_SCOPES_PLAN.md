# Architectural Plan: Implementing Chainable Scopes in Grant/Granite

## Executive Summary

This document outlines the architectural changes required to implement Rails-style chainable scopes in Grant/Granite. The implementation requires replacing the generic `Query::Builder(T)` with model-specific query builder classes that include scope methods.

## Current Architecture

### Query Building Flow
1. **Model Class** (e.g., `User < Granite::Base`)
   - Extends `Query::BuilderMethods` which delegates to `__builder`
   - Query methods like `where`, `order` create a new `Query::Builder(Model)`

2. **Query::Builder(Model)**
   - Generic class parameterized by model type
   - Contains query state (where clauses, order, limit, etc.)
   - Methods return `self` for chaining standard query methods

3. **Scopes**
   - Defined on model class only
   - Return `Query::Builder(Model)` instances
   - Cannot be chained because scope methods don't exist on `Query::Builder`

## Proposed Architecture

### New Query Building Flow
1. **Model Class** (e.g., `User < Granite::Base`)
   - Generates a custom `User::QueryBuilder < Granite::Query::Builder(User)`
   - All query methods return `User::QueryBuilder` instead of generic builder

2. **Model::QueryBuilder**
   - Custom class for each model
   - Inherits from `Granite::Query::Builder(Model)`
   - Contains all scope methods defined for that model
   - All methods return `Model::QueryBuilder` for chaining

3. **Scopes**
   - Defined on both model class and its QueryBuilder
   - Enable chaining: `User.active.recent.by_name("John")`

## Required Code Changes

### 1. Query::Builder Base Class Modifications
**File**: `src/granite/query/builder.cr`

**Changes**:
- Make it easier to subclass by extracting type-specific logic
- Ensure all methods can be overridden to return subclass type
- Add macro helpers for generating typed returns

```crystal
class Granite::Query::Builder(Model)
  # Change return types to use `self` instead of hardcoded class
  macro define_chainable_method(name, &block)
    def {{name}}(*args, **kwargs) : self
      {{block.body}}
      self
    end
  end
end
```

### 2. Base Model Modifications
**File**: `src/granite/base.cr`

**Changes**:
- Generate custom QueryBuilder class in `inherited` macro
- Override query initiation methods to use custom builder

```crystal
abstract class Granite::Base
  macro inherited
    # Generate custom query builder
    class QueryBuilder < ::Granite::Query::Builder({{@type}})
      # This will include scope methods
    end
    
    # Override builder creation
    def self.__builder
      db_type = # ... determine db type
      QueryBuilder.new(db_type)
    end
  end
end
```

### 3. Scoping Module Redesign
**File**: `src/granite/scoping.cr`

**Changes**:
- Modify `scope` macro to add methods to both model and QueryBuilder
- Ensure proper type returns for chaining

```crystal
module Granite::Scoping
  macro scope(name, body)
    # Add to model class
    def self.{{name.id}}
      result = {{body}}.call(__builder)
      result
    end
    
    # Add to QueryBuilder
    class QueryBuilder
      def {{name.id}}
        result = {{body}}.call(self)
        result
      end
    end
  end
end
```

### 4. Query Method Return Types
**Files**: All query-related files need updates
- `src/granite/query/builder.cr` - Update all methods to return `self`
- `src/granite/query/builder_methods.cr` - Delegate to custom builder
- `src/granite/querying.cr` - Use custom builder in class methods

### 5. Association Loading
**File**: `src/granite/eager_loading.cr`

**Changes**:
- Ensure eager loading methods return the custom builder type
- Update association queries to use custom builders

## Impact Analysis

### Breaking Changes

1. **API Changes**
   - Return types change from `Query::Builder(Model)` to `Model::QueryBuilder`
   - May break code that explicitly types query results
   - Example: `query : Granite::Query::Builder(User) = User.where(active: true)`

2. **Custom Query Extensions**
   - Any code extending `Query::Builder` needs updates
   - Custom query methods must be added to each model's QueryBuilder

3. **Type Inference**
   - More complex type hierarchy may impact compile times
   - Type errors might be less clear

### Features Likely Affected

1. **Associations** ✓ (Positive Impact)
   - Association queries can now use scopes
   - Example: `user.posts.published.recent`

2. **Eager Loading** ✓ (Positive Impact)
   - Can combine with scopes: `User.active.includes(:posts)`

3. **Query Caching** ⚠️ (Needs Review)
   - Custom builders might complicate query caching
   - Need to ensure cache keys work with new hierarchy

4. **Performance** ⚠️ (Needs Testing)
   - Additional class generation at compile time
   - Potential impact on binary size
   - Method dispatch might be slightly slower

5. **Database Adapters** ✓ (No Impact)
   - Adapters work with base Query::Builder
   - No changes needed

6. **Migrations** ✓ (No Impact)
   - Independent of query building

7. **Validations/Callbacks** ✓ (No Impact)
   - Operate on model instances, not queries

## Migration Strategy

### Phase 1: Backward Compatible Implementation
1. Keep existing `Query::Builder` working
2. Add feature flag for new behavior
3. Generate custom builders only when scopes are defined

### Phase 2: Gradual Migration
1. Update documentation with new patterns
2. Deprecation warnings for direct `Query::Builder` usage
3. Provide migration guide

### Phase 3: Full Cutover
1. Remove backward compatibility layer
2. Make custom builders mandatory
3. Clean up deprecated code

## Example Implementation

```crystal
# Before
class User < Granite::Base
  scope :active, ->(q : Query::Builder(User)) { q.where(active: true) }
  scope :recent, ->(q : Query::Builder(User)) { q.order(created_at: :desc) }
end

User.active  # Returns Query::Builder(User) - can't chain .recent

# After  
class User < Granite::Base
  scope :active, ->(q) { q.where(active: true) }
  scope :recent, ->(q) { q.order(created_at: :desc) }
end

User.active.recent.where(name: "John")  # Works! Returns User::QueryBuilder
```

## Risks and Mitigations

1. **Compile Time Impact**
   - Risk: Generating classes for every model increases compile time
   - Mitigation: Lazy generation, only for models with scopes

2. **Type Complexity**
   - Risk: More complex type errors for users
   - Mitigation: Clear documentation and error messages

3. **Maintenance Burden**
   - Risk: More complex codebase to maintain
   - Mitigation: Comprehensive tests and clear architecture

## Recommendation

This is a significant architectural change that should be implemented as part of a major version release (e.g., Grant 2.0). The benefits of chainable scopes and better query composition outweigh the costs, but it requires careful planning and execution.

The implementation should be done incrementally with extensive testing at each stage to ensure stability and performance.