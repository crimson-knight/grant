# Phase 2 Test Suite Stabilization - Refactoring Prompt

## Context
You are working on the Grant ORM project, which aims to achieve feature parity with Ruby on Rails' Active Record. During Phase 2 test suite stabilization (branch: `feature/phase-2-test-suite-stabilization`), several critical issues were discovered that require refactoring.

## Current State
- The test suite was stabilized by disabling problematic specs
- 9 spec files are currently disabled (`.disabled` extension)
- Core functionality works, but several advanced features are broken
- All issues are documented in `DISABLED_SPECS_REFACTOR.md` and `PHASE_2_STATUS.md`

## Priority Issues to Fix (Related to Current PR)

### 1. Polymorphic Associations - Critical Bug (Issue #17)
**Problem**: Crystal's type system prevents instantiation of abstract `Grant::Base` class
**Files**: 
- `spec/grant/associations/polymorphic_spec.cr.disabled`
- `spec/grant/associations/polymorphic_simple_spec.cr.disabled`
- `spec/support/polymorphic_models.cr.disabled`
- `spec/grant/associations/additional_options_spec.cr.disabled`

**Requirements**:
- Implement a type registry or factory pattern for polymorphic types
- Ensure concrete classes are instantiated, not the abstract base
- Fix type constraints and generic type handling
- Re-enable all polymorphic association tests

### 2. Eager Loading API Incompatibility (Issue #18)
**Problem**: Current API doesn't support Rails-style nested association syntax
**Files**: 
- `spec/grant/eager_loading/eager_loading_spec.cr.disabled`

**Current**: Only supports `includes(:posts, :comments)`
**Needed**: Support for:
```crystal
User.includes(:posts)
User.includes(posts: :comments)
User.includes(posts: [:comments, :likes])
User.includes(posts: { comments: :author })
```

**Requirements**:
- Update `includes` method signature to accept both symbols and hashes
- Implement recursive eager loading for nested associations
- Maintain backward compatibility

### 3. Scoping Macro Visibility (Issue #19)
**Problem**: Scope macros have visibility issues preventing proper usage
**Files**: 
- `spec/grant/scoping/named_scopes_spec.cr.disabled`

**Requirements**:
- Fix macro scope and visibility modifiers
- Ensure macros are properly exported from modules
- Verify macro expansion context
- Support lambda/proc-based scopes with parameters

### 4. Connection Management Features (Issue #11)
**Problem**: Missing read/write replica switching functionality
**Files**: 
- `spec/grant/connection_management_spec.cr.disabled`

**Missing**:
- `connection_switch_wait_period` method
- Automatic read/write adapter switching
- Replica lag handling

**Requirements**:
- Implement connection role switching (reading/writing)
- Add sticky primary connection after writes
- Implement health checks and failover

## Additional Test Issues to Fix

### 5. Lifecycle Callbacks Test Implementation
**Files**: 
- `spec/grant/callbacks/lifecycle_callbacks_spec.cr.disabled`

**Problem**: Tests try to add callbacks to instances rather than classes
**Fix**: Rewrite tests to use class-level callback definitions

### 6. Instrumentation Tests - Model Persistence
**Files**:
- `spec/grant/instrumentation/logging_spec.cr.disabled`
- `spec/grant/instrumentation/query_analysis_spec.cr.disabled`

**Problem**: `Model.create` returns nil or unpersisted objects in tests
**Fix**: Investigate why models aren't persisting properly in test environment

## Success Criteria
1. All 9 disabled spec files are re-enabled and passing
2. No functionality is removed - only fixed
3. All fixes maintain backward compatibility
4. Each fix includes appropriate test coverage
5. Update `PHASE_2_STATUS.md` to reflect completed fixes

## Approach Recommendations
1. Start with polymorphic associations as it's the most critical
2. Fix one issue at a time, re-enabling tests as you go
3. Run the full test suite after each fix to ensure no regressions
4. Document any API changes or design decisions
5. Consider creating smaller PRs for each major fix

## Detailed Task List and Execution Plan

### Priority 1: Polymorphic Associations (Critical)
**Tasks:**
1. Analyze polymorphic association implementation and Crystal type system constraints
2. Design type registry or factory pattern for polymorphic type instantiation
3. Implement polymorphic type resolution to avoid abstract Grant::Base instantiation
4. Re-enable and fix polymorphic_spec.cr, polymorphic_simple_spec.cr, and polymorphic_models.cr
5. Fix additional_options_spec.cr (depends on polymorphic fix)

**Solution Approach:**
- Design a type registry/factory pattern for polymorphic type resolution
- Ensure concrete classes are instantiated based on the polymorphic type value
- Fix type constraints and generic type handling

### Priority 2: Eager Loading API
**Tasks:**
6. Analyze current eager loading includes() method implementation
7. Update includes() method signature to accept symbols and nested hashes
8. Implement recursive eager loading for nested associations
9. Re-enable and fix eager_loading_spec.cr with Rails-style syntax support

**Solution Approach:**
- Update method signature to accept both symbols and hashes
- Implement recursive loading for nested associations like `includes(posts: { comments: :author })`
- Maintain backward compatibility

### Priority 3: Scoping Macro Visibility
**Tasks:**
10. Investigate scoping macro visibility issues in Crystal
11. Fix macro scope and visibility modifiers for proper module inclusion
12. Support lambda/proc-based scopes with parameters
13. Re-enable and fix scoping_spec.cr

**Solution Approach:**
- Investigation of Crystal macro expansion context
- Fix macro scope and visibility modifiers
- Support for lambda/proc-based scopes with parameters

### Priority 4: Connection Management
**Tasks:**
14. Implement connection_switch_wait_period method for models
15. Add automatic read/write adapter switching with sticky primary
16. Implement connection health checks and failover
17. Re-enable and fix connection_management_spec.cr

**Solution Approach:**
- Implement `connection_switch_wait_period` method
- Add automatic adapter switching with sticky primary after writes
- Health checks and failover mechanisms

### Priority 5: Test Implementation Fixes
**Tasks:**
18. Rewrite lifecycle callback tests to use class-level definitions
19. Re-enable and fix lifecycle_callbacks_spec.cr
20. Investigate model persistence issues in test environment
21. Fix Model.create to return persisted objects with IDs
22. Re-enable and fix logging_spec.cr and query_analysis_spec.cr

**Solution Approach:**
- Lifecycle callbacks: Rewrite tests to use class-level definitions
- Instrumentation: Fix model persistence issues causing `Model.create` to return nil

### Continuous Tasks:
23. Run full test suite after each major fix to ensure no regressions
24. Update PHASE_2_STATUS.md with completed fixes

## Execution Strategy
1. Start with polymorphic associations as it blocks multiple specs
2. Fix one issue completely before moving to the next
3. Run full test suite after each fix to prevent regressions
4. Re-enable specs incrementally as fixes are applied
5. Document all API changes and design decisions

## Testing Commands
```bash
# Run all tests
crystal spec

# Run specific re-enabled test
crystal spec spec/grant/associations/polymorphic_spec.cr

# Run with verbose output
crystal spec -v
```

## Resources
- Current implementation: Check `src/grant/associations/` for association code
- Rails Active Record source for reference patterns
- Crystal documentation for type system constraints
- Existing working tests for patterns to follow

## Notes
- The codebase uses the Grant namespace (will be renamed to Grant later)
- Maintain compatibility with PostgreSQL, MySQL, and SQLite
- Follow existing code style and patterns
- Add comments explaining any complex type system workarounds