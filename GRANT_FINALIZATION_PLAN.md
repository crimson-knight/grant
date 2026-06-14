# Grant: Finalization Plan (docs + compile-target rework + MySQL upstreaming)

Goal (Seth, 2026-06-13): finalize Grant's documentation so a fresh agent with
**zero prior context** can use the ActiveRecord pattern with Grant across devices
in a monorepo and use all methods effectively; and confirm how to manage /
contribute the `caching_sha2_password` work upstream with confidence across the
breadth of MySQL-compatible servers. Push to `main` is **gated on docs being
finalized AND validated**. Companion to `GRANT_MULTI_TARGET_AND_SCALE_PLAN.md`.

Two decisions confirmed:
- **Compile-target mechanism → idiomatic, no `-D` flags.** Adapter selection =
  which adapter you `require` per build entrypoint, with Crystal's native
  `shard.yml` `targets:` for the monorepo case. Per-target columns key off a
  `require "grant/target/<name>"` that sets a compile-time constant. Drop the
  `-D grant_target_*` flags and the `Grant.configure_target` macro.
- **MySQL → contribute to upstream PR #123 + bridge.** Upstream
  `crystal-lang/crystal-mysql` is actively maintained and PR #123 (maintainer
  bcardiff) already adds `caching_sha2_password`/`sha256_password`/auth-switch via
  a clean `src/mysql/auth.cr` seam. Do NOT fork long-term or monkey-patch.

---

## Thread A — Compile-target rework (no `-D` flags)

### A.1 New mechanism

- **Adapter availability** is just `require`s. The build entrypoint requires the
  adapter(s) it needs (`require "grant/adapter/pg"` etc.). For monorepos, use
  `shard.yml` `targets:` with one `main:` per build variant. **No flags, no
  `configure_target`.** Single-target apps need zero target machinery.
- **Per-target columns** key off a compile-time constant set by requiring a
  target file:
  - New files `src/target/{mobile,desktop,web}.cr`, each one line:
    `GRANT_COMPILE_TARGET = :mobile` (resp. `:desktop`, `:web`). Consumer path:
    `require "grant/target/mobile"`. Also support a user-defined custom target
    by letting them set `GRANT_COMPILE_TARGET` themselves before requiring models.
  - The `column` macro reads it at expansion via the top-level namespace, with a
    nil-safe default so untargeted builds get every column:
    ```
    # in the column macro, when `targets:` is present:
    {% active = @top_level.has_constant?("GRANT_COMPILE_TARGET") ? @top_level.constant("GRANT_COMPILE_TARGET") : nil %}
    {% if active == nil || targets.includes?(active) %} ...emit column... {% end %}
    ```
    (Verify the exact macro API — `@top_level.has_constant?` / `.constant` — and
    adjust; the requirement is: gated column present when its target is active OR
    when no target is set; absent otherwise. A `primary: true` gated column still
    fails to compile.)
  - The target constant must be defined **before** models expand (the entrypoint
    requires `grant/target/<name>` before `require "./models"`), exactly as the
    chosen design shows.

### A.2 Remove / rework

- **Remove** `Grant.configure_target` and its specs.
- **Keep** the lazy `url_provider : -> String` overload on
  `establish_connection`/`establish_connections` (still needed for device targets
  that compute their DB path at runtime).
- **Keep** `Grant::AdapterNotAvailableError` + the explicit guard-rail in
  `ConnectionRegistry#get_adapter`, and `Grant.compiled_adapters`.
- **Rework** `Grant.active_targets` / `Grant.target?` to read
  `GRANT_COMPILE_TARGET` instead of the `-D` flags.

### A.3 Tests + docs

- Rewrite the compile-target specs to the constant mechanism: a gated column is
  present under its target, absent under another, present when no target set;
  primary-gating fails to compile; composes with STI + #41 serialization.
- Rewrite `docs/compile_target_adapters.md` around the chosen model: single-target
  apps (just require an adapter), the monorepo `shard.yml targets:` pattern, the
  `grant/target/<name>` requires, per-target columns with a mobile↔web sync
  example, and the device→API→DB boundary. No `-D` flags anywhere.

Owner: one agent. Touches `src/grant/target.cr`, `src/grant/columns.cr`,
new `src/target/*.cr`, `src/grant.cr` (requires), the compile-target specs,
`docs/compile_target_adapters.md`. **This agent owns `columns.cr` and `target.cr`
entirely (incl. their doc comments) so the docs sweep can skip them.**

---

## Thread B — Documentation finalization (the push gate)

Bar: a cold agent (only the generated `crystal docs` + `docs/`) can build a
working monorepo cross-device Grant app using the AR pattern and all major
methods. Every public signature explicitly typed; every public method/macro has a
doc comment with a runnable example; `crystal docs` output maximized.

### B.1 Coverage baseline (from audit)

~35–40% doc-comment coverage, ~60–70% type coverage of the public API. Strong:
target, tenancy, STI, transactions, dirty-tracking, scoping (partial). Weak: core
CRUD + query + builder chaining lack return types; convenience methods lack docs;
macro-generated methods render poorly in `crystal docs`.

### B.2 Work, split by module group (parallel agents; each adds explicit
param+return types AND doc comments with `​```crystal` examples; build+test in
isolation; do NOT touch `columns.cr`/`target.cr` — Thread A owns those):

1. **Persistence/CRUD** — `transactions.cr` (`save`/`save!`/`update`/`update!`/
   `create`/`create!`/`destroy`/`import`/`update_attribute(s)`/`update_columns`/
   `increment!`/`decrement!`/`toggle!`), `transaction.cr`.
2. **Querying + builder** — `querying.cr` (`all`/`first`/`find`/`find_by`/
   `exists?`/`count`/`find_each`/`find_in_batches`), `query/builder.cr` chaining
   methods (`: self` everywhere), `convenience_methods.cr`
   (`pluck`/`pick`/`in_batches`/`annotate`).
3. **Associations + scoping** — `associations*` (`belongs_to`/`has_one`/
   `has_many`/through/polymorphic + generated getters, document the generated
   API), `scoping.cr` (`scope`/`default_scope`/`current_scope`/`unscoped`).
4. **Validations + callbacks** — `validators.cr` + `validators/` +
   `validation_helpers/` (`validates_*`, `validate`, `validates_with`, `:if`/
   `:unless`/`:on` examples), `callbacks.cr` + `commit_callbacks.cr`.
5. **Advanced features** — `encryption.cr`, `enum_attributes.cr`,
   `secure_token.cr`, `signed_id.cr`, `token_for.cr`, `serialized_column.cr`,
   `normalization.cr`, `value_objects.cr`.
6. **Scale + STI + connections** — `scale/*` (backfill the few missing types +
   docs), `sti.cr` (already good — fill gaps), `connection_management.cr` /
   `connection_registry.cr` (public surface).

### B.3 Crystal-docs polish (one agent, after B.2 merges)

- Review `disable_grant_docs?` gating — un-hide genuinely public methods
  (`new_record?`, `destroyed?`, `persisted?`, the public `initialize` overloads)
  unless there's a reason.
- Add a **"reading the generated API" note** explaining macro-generated methods
  (`<col>_changed?`, `<assoc>`, `<assoc>!`, etc.) since `crystal docs` renders
  them from templates.
- Add a **Quick Start** doc: the 10 most common operations end-to-end
  (define model → migrate → create → query → associations → validations →
  transaction), runnable.
- Write the **monorepo cross-device guide** (ties Thread A + tenancy + sync
  boundary into one worked example: shared models, mobile sqlite target, web pg
  target, per-target columns, what syncs via API).

### B.4 Validation (the gate) — one cold agent

Spawn an agent given ONLY the generated `crystal docs` output + `docs/` (NOT
`src/`), tasked to build a small but real monorepo app: shared model(s) used by a
sqlite "mobile" target and a pg "web" target, exercising create/find/where/
associations/validations/transaction/a per-target column. Record every point
where it needed information not in the docs → those are gaps → feed back into B.2/
B.3 and re-run until the cold agent succeeds with no `src/` peeking. Only then is
the docs gate met.

---

## Thread C — MySQL upstreaming + bridge + breadth

### C.1 Validate PR #123 live across the version matrix

- Fetch upstream PR #123 (`bcardiff` "Add multi-auth plugin support", targets
  v0.17.0, adds `src/mysql/auth.cr`). Inspect its full-auth path: does it do RSA-
  over-plaintext on a cache miss, and **what OAEP digest** (we found MySQL needs
  **SHA-1**, not SHA-256 — the bug our live testing caught)?
- Extend the Docker matrix and test #123 against: **MySQL 8.0.11** (first GA),
  **8.0.46**, **8.4.9 LTS** (native_password OFF by default — strictest),
  **9.7.0 LTS** (9.0.1 is superseded). Plus **MariaDB** latest LTS (confirm the
  `mysql_native_password` path still works — caching_sha2 is N/A for MariaDB) and
  optionally **Percona 8.x** (caching_sha2, same as MySQL).
- For each: fast-auth + full-auth (cold cache) round-trip. Capture evidence.

### C.2 Contribute upstream (prepare; do NOT post without Seth's go)

- If #123 has the SHA-256 OAEP issue or misses RSA-plaintext full-auth, port our
  SHA-1 fix and prepare: a draft PR review comment + a patch + the version-matrix
  test evidence. **Outward-facing — do not post to the public PR until Seth
  approves.**

### C.3 Bridge Grant until #123 releases

- Until #123 merges and a release ships, point Grant's `mysql` dep at the fixed
  #123 (the PR branch, or a thin branch rebased on `v0.17.0 + #123 + SHA-1 fix`).
  Set it up + run Grant's MySQL specs against the live matrix locally. When
  upstream releases, switch to the upstream release. (Our `v0.15.0`-based fork
  branch becomes obsolete.)
- Update grant `docker-compose.test.yml`/CI to the new matrix (add 8.4 + 9.7).

### C.4 Breadth-of-support doc

`docs/mysql_compatibility.md`: the matrix — caching_sha2 covers MySQL 8.0.4→9.7,
Percona, Aurora 8.4, Azure, TiDB, Vitess/PlanetScale (one implementation);
**MariaDB is the outlier** (defaults to `mysql_native_password`; secure =
`ed25519`/PARSEC; caching_sha2 only as an off-by-default shim in 12.1+). State
plainly that **ed25519 is the separate, unbuilt feature** real MariaDB security
support would need — a documented future gap, not part of this work.

---

## Sequencing

- **Round 1 (parallel, now):** Thread A (compile-target rework) + Thread C
  (MySQL validate/bridge/breadth — outward posting deferred to Seth). Merge +
  verify.
- **Round 2 (after A merges):** Thread B.2 docs sweep (6 module-group agents).
  Merge + verify build.
- **Round 3:** B.3 polish (Quick Start, monorepo guide, crystal-docs notes).
- **Round 4:** B.4 cold-agent validation loop until it passes.
- **Round 5 (gated):** push `main` to origin; surface the upstream PR
  contribution to Seth for posting; decide the bridge's final form.

Standard agent guardrails: worktree-isolated, test with `CURRENT_ADAPTER=sqlite`
(+ `SQLITE_DATABASE_URL=sqlite3:./granite.db`), never `git add lib`/`-A`, commit
to branch with the co-author trailer, do NOT push or post upstream.

## Out of scope / deferred (documented, not built)

- MariaDB `ed25519`/PARSEC auth (separate feature; flagged in C.4).
- The device↔server sync engine (boundary documented; protocol is separate).

---

## Progress — COMPLETE (2026-06-13)

All rounds done, validated, and shipped. `crimson-knight/grant` `main` pushed to
origin (`80fa836..fceb71f`, synced).

- **Thread A (compile-target rework):** shipped. `-D` flags + `configure_target`
  removed; adapter selection = plain requires + `shard.yml targets:`; per-target
  columns via `require "grant/target/<name>"` (`GRANT_COMPILE_TARGET`). Cold
  agent machine-verified isolation: mobile binary links sqlite + 0 pg symbols;
  web binary links pg + 0 sqlite symbols.
- **Thread B (docs finalization):** shipped + VALIDATED. 6-group type/doc/example
  sweep; guides (`quick_start.md`, `monorepo_cross_device.md`,
  `reading_the_generated_api.md`); un-hid `persisted?`/`new_record?`/`destroyed?`
  (were generated inside `macro inherited`, never rendered); `crystal docs
  -D grant_docs src/grant.cr` → 209 pages; `src/` fully formatted; 2 dead
  never-compiling files removed. **Cold-agent gate PASSED:** built a full monorepo
  app from docs alone, zero blocking gaps, no `src/` reads.
- **Cold-agent gate caught 3 real bugs, all fixed:** (1) `transaction` referenced
  all three adapter CONSTANTS → broke single-adapter builds (`undefined constant
  Grant::Adapter::Mysql`); switched to string dispatch like scoping/sti. (2)
  `has_many :books` now singularizes → `Book`. (3) `validates_presence_of/
  uniqueness_of/absence_of` now variadic.
- **Thread C (MySQL):** PR #123 validated live (already correct — SHA-1 OAEP)
  across MySQL 8.0.46/8.4.9/9.7.0 + Percona 8.0 + MariaDB 11.8; review comment
  POSTED to PR #123 (issuecomment-4700283264). **Bridge ACTIVATED:** `pr-123`
  pushed to `crimson-knight/crystal-mysql`; Grant `shard.yml` → `mysql @
  crimson-knight/crystal-mysql:pr-123` + `db ~> 0.14`; resolves to db 0.14 /
  mysql 0.17 / sqlite3 0.23 / pg 0.30; builds clean, SQLite specs at baseline.
  Switch to `version: ">= 0.17.0"` once #123 merges + releases.
- **Publishing:** Grant publishes as `amberframework/grant` (docs consistent;
  dev remote is `crimson-knight/grant`).

**Follow-ups (documented, not built):** MariaDB `ed25519`/PARSEC; the device↔
server sync protocol; retire the bridge when crystal-mysql ships #123.
