# Nested Attributes Implementation for Grant

## Summary

I've successfully implemented the foundation for nested attributes support in Grant (formerly Granite). The implementation provides:

### Completed Features:

1. **Module Structure** ✅
   - Created `Granite::NestedAttributes` module
   - Proper integration with `Granite::Base`

2. **accepts_nested_attributes_for Macro** ✅
   - Generates `<association>_attributes=` setter methods
   - Supports configuration options:
     - `allow_destroy: true/false` - Allow destruction of nested records
     - `update_only: true/false` - Only allow updates, no creation
     - `limit: N` - Limit number of nested records
     - `reject_if: :all_blank` - Reject attributes where all values are blank

3. **Attribute Processing** ✅
   - Accepts Array, Hash, or NamedTuple inputs
   - Normalizes attributes to consistent Hash format
   - Properly handles `_destroy` flag
   - Implements reject_if conditions
   - Enforces limit constraints

4. **Test Coverage** ✅
   - Basic functionality tests
   - Option behavior tests (reject_if, limit, update_only)
   - Mixed operation tests

### Current Implementation Status:

The implementation stores and processes nested attributes but does not yet perform actual database operations. The attributes are validated and stored in the model instance, ready for the next phase of implementation.

### Example Usage:

```crystal
class Author < Granite::Base
  has_many :posts
  has_one :profile
  
  accepts_nested_attributes_for :posts, 
    allow_destroy: true,
    reject_if: :all_blank,
    limit: 5
    
  accepts_nested_attributes_for :profile,
    update_only: true
end

# Usage
author = Author.new(name: "John Doe")
author.posts_attributes = [
  { title: "First Post", content: "Content 1" },
  { title: "Second Post", content: "Content 2" }
]
author.save # Currently saves author but not nested records
```

### Next Steps for Full Implementation:

1. **Database Operations**: 
   - Integrate with Granite's save lifecycle
   - Implement actual create/update/destroy operations
   - Handle foreign key assignment

2. **Association Integration**:
   - Dynamically determine association classes
   - Support all association types (has_many, has_one, belongs_to)

3. **Validation Propagation**:
   - Validate nested records before save
   - Propagate errors to parent model

4. **Transaction Support**:
   - Wrap all operations in database transactions
   - Rollback on any failure

### Technical Challenges Encountered:

1. **Callback System**: Crystal's macro system and Granite's callback implementation made it challenging to hook into the save lifecycle cleanly.

2. **Dynamic Class Resolution**: Crystal's compile-time type system makes it difficult to dynamically resolve association classes at runtime.

3. **Method Overriding**: Unlike Ruby, Crystal doesn't support method aliasing or easy runtime method redefinition.

### Files Created/Modified:

- `/src/granite/nested_attributes_simple_v2.cr` - Current working implementation
- `/spec/granite/nested_attributes_spec.cr` - Comprehensive test suite
- `/spec/granite/nested_attributes_simple_spec.cr` - Tests for current implementation
- `/src/granite/base.cr` - Added require for nested attributes module

The foundation is solid and provides a Rails-like API for nested attributes. The remaining work involves integrating with Granite's persistence layer to perform actual database operations.