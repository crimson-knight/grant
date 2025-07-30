# Grant-ActiveRecord Feature Parity Roadmap

This document outlines the missing features in Grant when compared to Rails ActiveRecord v8, organized by priority for implementation.

## Priority 1: Critical Missing Features (Core Functionality)

### 1.1 Eager Loading & Query Optimization
- **Eager Loading (`includes`)** - Prevent N+1 queries by loading associations in advance
- **Preloading (`preload`)** - Load associations in separate queries
- **Strict Loading (`strict_loading`)** - Raise errors when accessing non-loaded associations
- **Association Query Caching** - Cache association results after first query within same object instance
- **Joins with Association Names** - `.joins(:posts, :comments)` instead of raw SQL

### 1.2 Attribute Dirty Tracking API
- **Dirty Attributes** - Track changes to model attributes
  - `attribute_changed?`
  - `attribute_was`
  - `attribute_change`
  - `changes`
  - `changed?`
  - `changed_attributes`
  - `previous_changes`
  - `saved_changes`
  - `saved_change_to_attribute?`
  - `attribute_before_last_save`
  - `restore_attributes`

### 1.3 Advanced Callbacks
- **Missing Lifecycle Callbacks:**
  - `after_initialize`
  - `after_find`
  - `after_touch`
  - `before_validation`
  - `after_validation`
  - `after_commit`
  - `after_rollback`
  - `after_create_commit`
  - `after_update_commit`
  - `after_destroy_commit`
- **Conditional Callbacks** - `:if` and `:unless` options
- **Callback Chains** - Ability to define execution order

### 1.4 Scopes & Advanced Querying
- **Named Scopes** - `scope :published, -> { where(published: true) }`
- **Default Scopes** - `default_scope { order(created_at: :desc) }`
- **Unscoped** - Bypass default scope
- **Merge** - Combine query conditions from multiple scopes
- **Extending Queries** - Add methods to query chains
- **Or Queries** - Proper `or` query support (currently basic)

## Priority 2: Essential Features (Common Use Cases)

### 2.1 Advanced Associations
- **Polymorphic Associations** - `belongs_to :imageable, polymorphic: true`
- **Self-Referential Associations** - Better support for tree structures
- **Association Options:**
  - `dependent: :destroy/:nullify/:restrict`
  - `counter_cache: true`
  - `inverse_of:`
  - `optional: true` for belongs_to
  - `autosave: true`
  - `touch: true`
- **Association Extensions** - Add custom methods to associations
- **Has Many Through with Source** - `has_many :subscribers, through: :subscriptions, source: :user`

### 2.2 Attribute Features
- **Attribute API** - Define custom attributes with type casting
  - `attribute :price, :decimal`
  - Custom attribute types
  - Default values for attributes
- **Store Accessors** - JSON/Hash attribute accessors
- **Enum Attributes** - Built-in enum support with methods
  - `enum status: { draft: 0, published: 1 }`
  - Helper methods: `published?`, `draft!`
- **Serialized Attributes** - Serialize complex types

### 2.3 Validations
- **Built-in Validators:**
  - `validates_numericality_of`
  - `validates_format_of`
  - `validates_confirmation_of`
  - `validates_acceptance_of`
  - `validates_associated`
- **Validation Contexts** - `valid?(:create)`
- **Conditional Validations** - `:if`, `:unless` options
- **Custom Validators** - Reusable validator classes

### 2.4 Database Features
- **Database Views Support** - Models backed by views
- **Prepared Statements** - Better prepared statement management
- **Connection Pooling Configuration** - More control over pool settings
- **Multiple Database Support** - Read/write splitting, horizontal sharding
- **Database-specific Features:**
  - PostgreSQL: Arrays, HStore, JSONB, Range types
  - MySQL: Spatial types
  - Full-text search indexes

## Priority 3: Advanced Features (Enterprise & Performance)

### 3.1 Caching
- **Query Cache** - Cache query results within request
- **Second Level Cache** - Cache across requests
- **Identity Map** - Ensure single object instance per record
- **Cache Versioning** - Handle cache invalidation
- **Fragment Caching Integration**

### 3.2 Advanced Query Interface
- **Arel Integration** - Lower-level query building
- **Subqueries** - `where(id: Model.select(:id))`
- **Window Functions** - Support for SQL window functions
- **Common Table Expressions (CTEs)**
- **Select Distinct On** (PostgreSQL)
- **Lateral Joins**

### 3.3 Performance Features
- **Explain** - `Model.where(...).explain`
- **Query Annotations** - Add comments to SQL queries
- **Optimizer Hints** - Database-specific query hints
- **Partial Indexes Support**
- **Expression Indexes**

### 3.4 Inheritance & STI
- **Single Table Inheritance (STI)** - `type` column for inheritance
- **Abstract Classes** - `self.abstract_class = true`
- **Delegated Types** - Alternative to STI

## Priority 4: Nice-to-Have Features

### 4.1 Convenience Methods
- **Pluck Multiple Columns** - `pluck(:id, :name)`
- **Pick** - `pick(:id, :name)` returns single record values
- **In Batches** - More batch processing options
- **Upsert All** - Bulk upsert operations
- **Insert All** - Bulk insert with more options
- **Annotate Queries** - Add source location to queries

### 4.2 Schema & Migration Enhancements
- **Schema Cache** - Cache table structure
- **Schema Versioning**
- **Reversible Migrations** - Better up/down tracking
- **Migration Generators**
- **Schema Dumping** - Export schema to SQL/Ruby

### 4.3 Testing Support
- **Fixtures** - YAML fixtures for testing
- **Factory Integration**
- **Database Cleaner Integration**
- **Transactional Tests**
- **Test Database Management**

### 4.4 Instrumentation & Monitoring
- **ActiveSupport::Notifications Integration**
- **Query Logging with Tags**
- **Slow Query Detection**
- **Database Performance Metrics**

## Implementation Strategy

### Phase 1 (Months 1-3): Foundation
1. Eager Loading & Association Caching
2. Dirty Tracking API
3. Core Missing Callbacks
4. Named Scopes

### Phase 2 (Months 4-6): Essential Features
1. Polymorphic Associations
2. Advanced Association Options
3. Attribute API with Types
4. Built-in Validators

### Phase 3 (Months 7-9): Advanced Features
1. Query Cache
2. Multiple Database Support
3. STI Support
4. Advanced Query Features

### Phase 4 (Months 10-12): Polish & Optimization
1. Performance Features
2. Testing Support
3. Instrumentation
4. Documentation & Examples

## Breaking Changes to Consider

1. **Association Loading Behavior** - May need to change default behavior
2. **Validation API** - Might need to restructure current implementation
3. **Callback System** - Current system may need overhaul
4. **Query Interface** - Some methods might need renaming for consistency

## Notes

- Focus on maintaining Crystal idioms while achieving ActiveRecord compatibility
- Consider performance implications of each feature
- Maintain backward compatibility where possible
- Provide migration guides for breaking changes
- Ensure comprehensive testing for each new feature