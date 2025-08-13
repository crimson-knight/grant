# Scoping Refactor Notes

## Current Issues

The scoping module has several architectural issues that need to be resolved:

### 1. Macro Visibility and Ordering
- The `scope` and `default_scope` macros need to be available at the module level
- Default scope constant references cause compilation errors due to macro ordering
- The system tries to apply scoping to non-model classes (validators, etc.)

### 2. Integration with Query System
- The `current_scope` method conflicts with existing query methods
- Default scope application happens too broadly, affecting validator classes
- The override methods need better integration with the base query system

### 3. Implementation Challenges
- Crystal's compile-time type system makes it difficult to conditionally apply scoping
- Runtime checks for class types are limited in Crystal
- The macro system doesn't allow for complex conditional logic

## Proposed Solutions

### 1. Separate Scoping Module
Create a dedicated scoping system that:
- Only applies to classes that explicitly include it
- Uses a different approach for default scopes (perhaps class properties)
- Better integrates with the existing query builder

### 2. Query Builder Extension
Instead of overriding methods, extend the query builder:
- Add scoping support directly to the query builder
- Use a flag or property to track default scope application
- Make scoping opt-in rather than automatic

### 3. Simplified Macro System
- Move scope definitions to a simpler system
- Avoid complex compile-time checks
- Use explicit registration for scoped models

## Test Coverage

The scoping spec tests:
- Named scopes (published, active, high_priority, etc.)
- Default scopes (soft delete pattern)
- Unscoped queries
- Scope chaining
- Integration with other query methods

All these features need to be preserved in any refactor.

## Dependencies

Before refactoring scoping, consider:
- How it integrates with eager loading
- Connection management implications
- Impact on existing query methods
- Backward compatibility requirements

## Recommendation

This requires a deeper architectural change to Grant's query system. It should be tackled as a separate feature branch with careful consideration of the entire query API.