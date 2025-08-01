# Active Record Parity - Branch Planning

## Branch Naming Convention

All branches follow: `feature/phase-{number}-{feature-group-name}`

## Phase 1: Critical Infrastructure
**Branch**: `feature/phase-1-critical-infrastructure`
**Timeline**: 3 months
**Features**:
- Connection pooling with crystal-db
- Multiple database support (connects_to DSL)
- Horizontal sharding
- Explicit transactions
- SQL sanitization
- Locking (optimistic & pessimistic)

## Phase 2: Security & Async
**Branch**: `feature/phase-2-security-async`
**Timeline**: 2 months
**Features**:
- Encryption support
- Async convenience methods (async_count, async_sum, etc.)
- Secure tokens
- Signed IDs
- Advanced query methods

## Phase 3: Developer Experience
**Branch**: `feature/phase-3-developer-experience`
**Timeline**: 2 months
**Features**:
- Nested attributes
- Query caching
- Normalization
- Store accessors
- Where chains
- Aggregations

## Phase 4: Performance & Polish
**Branch**: `feature/phase-4-performance-polish`
**Timeline**: 1 month
**Features**:
- Query optimization
- Batch operations improvements
- Performance monitoring
- Documentation updates
- Migration guides

## Current Status

✅ **Previous Phases Completed**:
- Phase 1: Dirty Tracking & Callbacks (completed)
- Phase 2: Polymorphic Associations (completed)
- Phase 3: Enum Attributes & Validators (completed)
- Phase 4: Convenience Methods & Instrumentation (completed)

🚧 **Current Phase**:
- Phase 1: Critical Infrastructure (starting)

## Merge Strategy

1. Each phase branch is created from `main`
2. Regular commits to phase branch
3. PR created when phase is complete
4. Merge to `main` after review
5. Tag release for each completed phase

## Branch Protection Rules

- All phase branches require PR reviews
- Must pass all tests
- Must maintain backward compatibility
- Must include documentation updates