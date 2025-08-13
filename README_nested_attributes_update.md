# Nested Attributes Implementation Update

## Phase 2 - Persistence Layer Attempt

### Summary

I've attempted to implement the persistence layer for nested attributes, encountering several challenges with Crystal's compile-time type system:

### Technical Challenges:

1. **Callback Integration**: Crystal's macro system and Grant's callback implementation make it difficult to hook into the save lifecycle cleanly. The `CALLBACKS` constant is not available when modules are included.

2. **Method Override Timing**: Unlike Ruby, Crystal requires methods to exist before they can be overridden with `previous_def`. The `save` method doesn't exist when the NestedAttributes module is included.

3. **Type Introspection**: Crystal doesn't allow runtime type introspection or dynamic class resolution. Attempting to use `TypeNode#instance_vars` at compile time fails because instance variables aren't initialized yet.

4. **Association Metadata Access**: While associations store metadata, accessing it dynamically at compile time is challenging.

### Current Implementation:

The implementation successfully:
- ✅ Stores and validates nested attributes
- ✅ Implements all configuration options (reject_if, limit, update_only, allow_destroy)
- ✅ Provides a clean API matching Rails conventions
- ✅ Passes all validation and storage tests

The implementation does NOT yet:
- ❌ Actually create, update, or destroy nested records in the database
- ❌ Hook into the save lifecycle automatically
- ❌ Handle validation propagation from nested records

### Workaround:

I've added a `save_with_nested_attributes` method that can be called instead of `save` to handle nested attributes. This is a temporary solution until we can properly integrate with Grant's save lifecycle.

### Next Steps:

1. **Custom Save Method**: Create a module that properly overrides save using a different approach (perhaps using `macro finished` or a different hook point).

2. **Explicit Class Mapping**: Instead of trying to resolve classes dynamically, require explicit class specification in the `accepts_nested_attributes_for` macro.

3. **Code Generation**: Generate specific methods for each association that handle the persistence logic without requiring runtime type resolution.

4. **Integration with Transactions**: Ensure all nested operations are wrapped in database transactions.

The foundation is solid and the API is complete. The remaining work is primarily about finding the right integration points within Crystal's type system constraints.