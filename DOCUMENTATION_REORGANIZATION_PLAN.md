# Grant Documentation Reorganization Plan

## Overview
This document tracks the progress of reorganizing Grant's documentation for optimal ChromaDB vector storage integration. The goal is to reduce ~80 documentation files to ~35 focused, well-organized documents with proper metadata and chunking.

## Status: 🚧 In Progress

### Phase 1: Critical User Documentation ✅
- [x] Create new getting-started structure
  - [x] Merge `/README.md` + `/docs/readme.md` → `/docs/getting-started/installation.md`
  - [x] Create `/docs/getting-started/quick-start.md` (15-minute tutorial)
  - [x] Extract database setup → `/docs/getting-started/database-setup.md`
  - [x] Create `/docs/getting-started/first-model.md` (tutorial format)
- [x] Consolidate core features documentation
  - [x] Merge `models.md` + enhancements → `/docs/core-features/models-and-columns.md`
  - [x] Update `crud.md` with examples → `/docs/core-features/crud-operations.md`
  - [x] Merge `querying.md` + scoping → `/docs/core-features/querying-and-scopes.md`
  - [x] Combine `relationships.md` + `advanced_associations.md` → `/docs/core-features/relationships.md`
  - [x] Consolidate validation docs → `/docs/core-features/validations.md`
  - [ ] Update callbacks → `/docs/core-features/callbacks-lifecycle.md`
- [x] Merge overlapping query documentation
  - [x] Combine 4 query docs → `/docs/core-features/querying-and-scopes.md`
- [ ] Create comprehensive API reference
  - [ ] Extract model methods → `/docs/api-reference/model-methods.md`
  - [ ] Document association options → `/docs/api-reference/association-options.md`
  - [ ] Consolidate validators → `/docs/api-reference/validation-helpers.md`

### Phase 2: Advanced Features Organization ⏳
- [ ] Performance documentation
  - [ ] Consolidate eager loading docs → `/docs/advanced/performance/eager-loading.md`
  - [ ] Create query optimization guide → `/docs/advanced/performance/query-optimization.md`
- [ ] Data management documentation
  - [ ] Move dirty tracking → `/docs/advanced/data-management/dirty-tracking.md`
  - [ ] Update migrations → `/docs/advanced/data-management/migrations.md`
  - [ ] Enhance imports/exports → `/docs/advanced/data-management/imports-exports.md`
  - [ ] Move normalization → `/docs/advanced/data-management/normalization.md`
- [ ] Security documentation
  - [ ] Merge 3 encryption docs → `/docs/advanced/security/encrypted-attributes.md`
  - [ ] Update secure tokens → `/docs/advanced/security/secure-tokens.md`
  - [ ] Consolidate signed IDs → `/docs/advanced/security/signed-ids.md`
- [ ] Specialized features
  - [ ] Move enum attributes → `/docs/advanced/specialized/enum-attributes.md`
  - [ ] Update polymorphic associations → `/docs/advanced/specialized/polymorphic-associations.md`
  - [ ] Move value objects → `/docs/advanced/specialized/value-objects.md`
  - [ ] Update serialized columns → `/docs/advanced/specialized/serialized-columns.md`

### Phase 3: Infrastructure Documentation ⏳
- [ ] Multiple databases
  - [ ] Create setup/configuration guide → `/docs/infrastructure/multiple-databases/setup-configuration.md`
  - [ ] Consolidate connection management → `/docs/infrastructure/multiple-databases/connection-management.md`
  - [ ] Merge 7+ sharding files → `/docs/infrastructure/multiple-databases/sharding-guide.md`
- [ ] Async operations
  - [ ] Update async queries → `/docs/infrastructure/async-operations/async-queries.md`
  - [ ] Document concurrency → `/docs/infrastructure/async-operations/concurrency.md`
- [ ] Instrumentation
  - [ ] Merge logging/monitoring → `/docs/infrastructure/instrumentation/logging-monitoring.md`
  - [ ] Consolidate query analysis → `/docs/infrastructure/instrumentation/query-analysis.md`
  - [ ] Extract performance metrics → `/docs/infrastructure/instrumentation/performance-metrics.md`
- [ ] Transactions and locking
  - [ ] Consolidate locking docs → `/docs/infrastructure/transactions-locking/locking-strategies.md`
  - [ ] Update transaction management → `/docs/infrastructure/transactions-locking/transaction-management.md`

### Phase 4: Development Documentation ⏳
- [ ] Consolidate design documents
  - [ ] Merge all *_DESIGN.md files → `/docs/development/architecture/design-decisions.md`
- [ ] Create unified architecture documentation
  - [ ] Consolidate ActiveRecord analysis → `/docs/development/architecture/active-record-parity.md`
  - [ ] Create roadmap from PHASE files → `/docs/development/architecture/roadmap.md`
- [ ] Organize migration guides
  - [ ] Create Granite to Grant guide → `/docs/development/migration-guides/granite-to-grant.md`
  - [ ] Extract version upgrade info → `/docs/development/migration-guides/version-upgrades.md`
  - [ ] Document API changes → `/docs/development/migration-guides/api-changes.md`
- [ ] Development guides
  - [ ] Extract contributing info → `/docs/development/contributing.md`
  - [ ] Consolidate testing info → `/docs/development/testing-guide.md`

### Phase 5: ChromaDB Optimization ⏳
- [ ] Add metadata to all documents
  - [ ] Add YAML frontmatter with categories, tags, complexity levels
  - [ ] Add prerequisites and related document links
  - [ ] Add database support indicators
- [ ] Optimize content chunking
  - [ ] Ensure concept chunks are 300-800 words
  - [ ] Make code examples complete and runnable
  - [ ] Verify self-contained chunks
- [ ] Create indexes
  - [ ] Build cross-reference index
  - [ ] Add semantic tags
  - [ ] Create relationship mappings

## Files to Delete (After Consolidation)

### Redundant Phase Files
- [ ] `PHASE1_IMPLEMENTATION_SUMMARY.md`
- [ ] `PHASE_1_COMPLETION_SUMMARY.md`
- [ ] `PHASE1_WEEK1_SUMMARY.md`
- [ ] `PHASE1_COMPILATION_FIXES.md`

### Redundant Summary Files
- [ ] `HORIZONTAL_SHARDING_SUMMARY.md`
- [ ] `ENCRYPTION_SUMMARY.md`
- [ ] `LOCKING_IMPLEMENTATION_SUMMARY.md`

### Redundant README Files
- [ ] `README_nested_attributes.md`
- [ ] `README_nested_attributes_update.md`

## ChromaDB Metadata Template

```yaml
---
title: "Document Title"
category: "core-features" | "advanced" | "infrastructure" | "development"
subcategory: "specific-subcategory"
tags: ["orm", "database", "crystal", "feature-tags"]
complexity: "beginner" | "intermediate" | "advanced" | "expert"
version: "1.0.0"
prerequisites: ["installation.md", "first-model.md"]
related_docs: ["related1.md", "related2.md"]
last_updated: "2025-01-13"
estimated_read_time: "X minutes"
use_cases: ["web-development", "api-building"]
database_support: ["postgresql", "mysql", "sqlite"]
---
```

## Progress Metrics
- Total files to process: ~80
- Target file count: ~35
- Files processed: 20
- Files merged: 12 (README+readme→installation, models→models-and-columns, 4 query docs→querying-and-scopes, 3 relationship docs→relationships, 2 validation docs→validations)
- Files deleted: 0
- Files with metadata: 11 (all new docs have metadata)

## Notes
- Prioritize user-facing documentation first
- Ensure backward compatibility in URLs where possible
- Keep old files until consolidation is verified
- Test ChromaDB retrieval after each phase

---
Last Updated: 2025-01-13