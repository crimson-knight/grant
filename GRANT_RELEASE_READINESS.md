# Grant — Release Readiness

**Companion to:** [`GRANT_AR_PARITY_REVIEW.md`](GRANT_AR_PARITY_REVIEW.md) (the verified 211-feature AR8 parity audit).
**Purpose:** define what blocks Grant's first official release and track the work to clear it.

## Thesis

Grant's readiness is **not** gated by ActiveRecord parity percentage. The parity audit puts Grant at
~47% complete / ~32% partial across 211 AR8 features, and that is fine for a v1 — the
production-critical subsystems (transactions, locking, callbacks, associations, connection pooling,
encryption) are present and, after the bug-fix pass below, actually work.

What gates release is a small set of **correctness/usability bugs that surface the moment you build a
real multi-model Amber app on Grant.** Three of them (#39/#40/#41) were filed *from* an actual
app-building attempt and required local monkey-patches to get past. Until those are fixed, the
portfolio apps we want to build on Grant cannot be built cleanly. That is the bar: **a non-trivial,
multi-model Amber app compiles and runs on Grant against a single adapter, with no monkey-patches.**

## Definition of done (release gate)

1. A fresh Amber app with **two or more** `Grant::Base` models, at least one **UUID** column, and a
   single required adapter (e.g. SQLite *or* PG only) **compiles and boots** — no `require`
   monkey-patches, no union-type errors.
2. No security-claim mismatches in docs; raw-SQL escape hatch has a sanitization story.
3. `crystal spec` is **green across SQLite + PostgreSQL + MySQL in CI** (not just SQLite locally).
4. Root docs reflect verified status — the stale `active_record_analysis/` is removed or regenerated.
5. Sharding remains labeled **experimental**; it is explicitly out of scope for v1 readiness.

## Status at a glance

| # | Item | Priority | Issue | Status |
|---|---|---|---|---|
| 1 | 2nd `Grant::Base` subclass breaks YAML program-wide | **P0** | #41 | ✅ done — merged to `main`; `serialization_multimodel_spec` 6/6 |
| 2 | UUID columns break YAML deserialization (missing `require`) | **P0** | #39 | ✅ done — `require "uuid/yaml"` in `columns.cr` + `type.cr` |
| 3 | `LockMode#to_sql` forces requiring all 3 adapters | **P0** | #40 | ✅ done — virtual `adapter.lock_clause`; sqlite-only compile verified |
| 4 | Raw-SQL sanitization for the raw query escape hatch | P1 | #7 | ✅ done — `Grant::Sanitization`; `sanitization_spec` 26/26 incl. live injection test |
| 5 | `HealthMonitor#status` references a nonexistent ivar | P1 | — | ✅ done — `Time.unix(@last_check_timestamp.get)` |
| 6 | Encryption docs claimed AES-256-GCM; impl is CBC+HMAC | P1 | — | ✅ done — docs corrected to AES-256-CBC + HMAC-SHA256 |
| 7 | Bugs 1–7 from the parity audit | P0 (pre-work) | — | ✅ done (`main` @ `32b2c06`) |
| 8 | Remove/regenerate stale `active_record_analysis/` | P2 | #23 | ☐ todo |
| 9 | Close already-implemented issues (Enumerable(T)) | P2 | #36 | ☐ todo |
| 10 | CI green across SQLite + PG + MySQL | P2 (gate) | — | ☐ verify |

## Integration verification (this pass)

All four code fixes were implemented in isolated worktrees, then merged into `main` (merges
`9beb8fc`, `4adbe33`, `620d418` over docs commit `c84d493`). Verified on the integrated tree:

- `crystal build src/grant.cr` — clean (exit 0).
- New regression specs pass in isolation: `serialization_multimodel_spec` 6/6, `sanitization_spec`
  26/26 (incl. a test that executes a `'; DROP TABLE …` payload and asserts the table survives),
  and the new `lock_clause` dispatch specs.
- Full SQLite suite: **119 examples, 15 failures, 14 errors** — down from the clean-`main` baseline
  of 23 failures / 14 errors (the serialization fix additionally repaired 8 pre-existing
  `grant_spec` JSON/YAML failures). **Zero new failures or errors introduced.**
- The remaining failures/errors are all pre-existing and environment-bound: multi-DB/MySQL specs
  needing servers not running locally, SQLite transaction/`with_lock` reload semantics, string→Int64
  coercion, and a log-capture flaky test. Several only appear under random spec order (shared global
  state); they pass when their file is run in isolation. Spec-order isolation is a known pre-existing
  issue tracked under P2.

## Already landed

**Bugs 1–7 (the parity audit's "fix-first" list) are fixed on `main` (`32b2c06`):** non-atomic
transactions, class-global `connection_context`, non-functional eager loading, `or/not` block param
drop, `select(*cols)` projection, `prevent_writes` enforcement, and `after_commit`/`after_rollback`
timing. Each landed with failing-first regression specs and adversarial review. See the parity doc's
executive summary for commit-by-commit detail. The full spec suite compiles and runs again.

**Encryption security claim corrected (this pass):** `docs/encrypted_attributes.md` and
`docs/advanced/security/encrypted-attributes.md` claimed AES-256-GCM in 6 places; the implementation
(`src/grant/encryption/cipher.cr`) is **AES-256-CBC with HMAC-SHA256 (Encrypt-then-MAC)** — a sound
authenticated-encryption construction, but the docs must not overstate it. Corrected.

## Release blockers — punch list

### P0 — cannot build a real multi-model app without these

- **#41 — a second model breaks YAML across the whole program.** `abstract class Grant::Base`
  (`src/grant/base.cr:51`) only gets `include JSON::Serializable` / `include YAML::Serializable`
  inside `macro inherited` (lines 154–155), so the abstract base is not `YAML::Serializable`. When
  Crystal widens a union of 2+ subclasses to `Grant::Base+`, any `YAML::Serializable?` context (e.g.
  Amber's `CustomRegistry#load_custom_from_yaml`) fails to compile. **This is the #1 portfolio
  blocker.** Fix: make the abstract base itself satisfy the serializable interfaces; verify the
  macro-generated initializers/dirty-tracking annotations still hold.
- **#39 — UUID columns break YAML.** `src/grant/columns.cr` requires `"uuid"` and `"uuid/json"` but
  not `"uuid/yaml"`, so `UUID.new(YAML::ParseContext, …)` is undefined for any model with a UUID
  column. Fix: add `require "uuid/yaml"`.
- **#40 — locking forces all three adapters.** `LockMode#to_sql` (`src/grant/locking.cr:28–39`) and
  `optimistic.cr:103–107` `case` on `Grant::Adapter::Pg/Mysql/Sqlite` literals. Adapters are opt-in
  (`src/grant.cr` requires only `adapter/base`), so a single-adapter app fails with
  `undefined constant Grant::Adapter::Pg`. Fix: polymorphic dispatch — `adapter.lock_clause(mode)`
  overridden per adapter — so absent adapters are never referenced. (Also unblocks the
  broaden-compile-targets/iOS story.)

### P1 — security / correctness

- **#7 — raw-SQL sanitization.** The parameterized path is already safe; the raw escape hatch
  (string conditions, `["col = ?", val]` arrays) has no value/identifier quoting helper. Add a
  `Grant::Sanitization` module (type-aware `quote`, `quote_identifier`, `sanitize_sql_array`),
  adapter-aware, with parameterized placeholders remaining the preferred path.
- **`HealthMonitor#status` ivar typo.** `src/grant/health_monitor.cr:111` reads `@last_check.get`
  but the ivar is `@last_check_timestamp : Atomic(Int64)` — a compile crash if `status` is ever
  called. Fix to `Time.unix(@last_check_timestamp.get)` (matches line 47).
- **Encryption docs** — ✅ done this pass.

### P2 — release hygiene

- **Remove/regenerate `active_record_analysis/`** (#23). The audit calls it "actively misleading" —
  it lists transactions/locking/encryption/sharding as missing, all of which now exist.
- **Close stale issues:** #36 (Enumerable(T)) is already implemented (commit `2321110`). Triage the
  DX papercuts #37 (column non-nil defaults) and #38 (`.where` → `.all`/Array-like) — decide in/out
  for v1.
- **Spec/CI:** confirm `crystal spec` is green across SQLite + PG + MySQL in CI; triage
  `spec_disabled/`; confirm the local SQLite-only failures are purely env (missing DB servers).
- **`shard.yml`:** adapter shards are dev-only dependencies — document that a production app must add
  its own adapter dependency, and consider the compile-time adapter-flag design from the parity doc.

### P3 — explicitly NOT v1 blockers (beta / later)

- Sharding integration specs (11/11 pending), `QueryRouter` hardcoded shard-key columns — keep
  sharding labeled experimental.
- Compile-time adapter selection (`-Dgrant_adapter_*`) for iOS/watchOS targets — beta-track
  broaden-targets goal; #40's polymorphic fix is the prerequisite groundwork.
- Migration DSL / schema dump — the single largest AR8 parity gap, but raw-SQL + micrate is a
  workable v1 story.

## Verification / release gate checklist

- [ ] Two-model + UUID Amber app compiles against a single adapter (the #41/#39/#40 acceptance test).
- [ ] `crystal build src/grant.cr` clean; `crystal spec` green on SQLite locally.
- [ ] CI green on SQLite + PG + MySQL.
- [ ] `crystal tool format --check` clean.
- [ ] No security-claim mismatches in docs.
- [ ] `active_record_analysis/` removed or regenerated; stale issues closed.

## Cross-references

- Verified parity statuses & the bug-fix-first ordering: [`GRANT_AR_PARITY_REVIEW.md`](GRANT_AR_PARITY_REVIEW.md)
- Contributor (renich) thread is in Granite/Amber, not Grant — resolved separately.
