# Compile memory

Every model a program declares and queries adds to the compiler's memory use,
because Crystal instantiates a generic query stack (`Query::Builder(Model)`,
the assemblers, the executors) and the generated model methods once per
model. This page records what the compile-memory batch (PERF02) changed,
what it measured, and the commands to measure again.

Numbers are the compiler's peak resident set in MB (decimal), with an empty
`CRYSTAL_CACHE_DIR`, one compile at a time through `crystal-slot`, on
crystal-alpha 1.21.0. "Before" is `parity/wave-6` at `8bb661d`; "after" is this
branch. "Semantic" is `crystal build --no-codegen`; "debug" is a plain
`crystal build`. Current CI limits and local reproduction commands are in
[`docs/PERFORMANCE_BUDGETS.md`](PERFORMANCE_BUDGETS.md).

## What changed

1. **Association loading is reached per model.** `Builder#select_single` called
   `AssociationLoader.load_associations`, which called each record's
   `_eager_batch_load` through `Grant::Base`. The compiler therefore treated
   every model's loader (and every association target's full relation stack)
   as reachable from any query. The loader now dispatches through
   `AssociationLoader.enable(Model)` entries. `includes`, `preload`,
   `eager_load`, `Grant::Preloader`, and the loaders the association macros
   generate for their targets enable the models they load, so only models that
   can really load associations are compiled for it. Nested includes,
   through associations, polymorphic targets, and STI subclasses (found through
   the root's entry) behave as before.
2. **Association mass-assignment writers are per model.** The macros used to
   register a `Proc(Grant::Base, ..., Bool)` writer per association in a global
   table, which instantiated every target's setters whether or not anything was
   mass-assigned. Each association now defines a typed
   `_grant_write_assoc_<name>` method, and `Grant::AssociationWriters`
   generates one `_grant_assign_association` dispatcher per model, reached only
   from `set_attributes` (and so `new(**)`, `assign_attributes`,
   `attributes=`). `AssociationRegistry.register_writer` stays for hand-made
   writers.
3. **Predicate rendering is shared.** WHERE rendering, field quoting, and raw
   statement binding moved to `Query::Assembler::PredicateRenderer`, which takes
   the model's name, table, columns, and adapter as values and is compiled once
   instead of once per model and SQL dialect.
4. **Inherited scopes merge without a pair of models.** `Scoping` folded a
   parent class's `scoping { }` relation into a subclass relation through
   `Builder(Model)` on both sides, which instantiated the merge once per pair
   of models (quadratic: 100 models made 10,000 copies). Scope entries now
   export a model-independent `Query::ForeignRelation`.
5. **Chunked write terminals share one transaction.** `Model.transaction`
   yields, so each model's chunked `update_all`/`delete_all` held its own copy
   of the transaction machinery (about 69,000 IR lines per model). They now go
   through `Query::InChunks.in_transaction`.
6. **Association registration uses one metadata type.** The registration calls
   no longer instantiate the registry and `Reflection` constructors once per
   association target.

No public API or behavior changed, with one addition: loading associations on a
model nothing enabled raises `Grant::PreloadNotEnabledError` instead of
silently skipping (see Breaking changes in the batch report: only direct
callers of `AssociationLoader.load_associations` are affected).

## Results

### Scaling probes (semantic peak MB)

`scripts/compile_memory.py` generates N models of 8 columns each. `query`
runs one `where(...).each` per model; `assoc` adds a `belongs_to` and a
`has_many` in a ring and queries every model; `assoc_one` has the ring but
queries one model; `assoc_none` and `none` query nothing.

| Probe | N | Before | After |
| --- | ---: | ---: | ---: |
| query | 10 | 718 | 708 |
| query | 50 | 1,674 | 1,407 |
| query | 100 | 3,138 | 2,285 |
| query | 200 | 7,665 | 4,412 |
| assoc | 10 | 1,077 | 708 |
| assoc | 50 | 3,393 | 1,459 |
| assoc | 100 | 6,639 | 2,595 |
| assoc | 200 | not run (above 13,000) | 5,054 |
| assoc_one (one query) | 200 | 13,423 | 1,690 |
| assoc_none (no query) | 200 | 13,590 | 1,654 |
| none (no associations, no query) | 200 | 905 | 905 |

Slope, N=10 to N=200, MB per model: `query` 36.6 before, 19.5 after; `assoc`
22.9 after (N=10 to N=100: 61.7 before, 21.0 after).

### Debug builds (peak MB)

| Build | Before | After |
| --- | ---: | ---: |
| `spec/grant/associations/association_regressions_spec.cr` alone | 9,674 | 6,887 |
| `bench/lifecycle_bench.cr`, one model | 1,896 | 1,804 |

### Targets that are not met

| Target | Result |
| --- | --- |
| 200-model one-query associated probe at most 1,600 MB semantic | 1,690 (5.6% over). With one query the cost is almost all declaration: `assoc_none` is 1,654. |
| semantic slope at most 7.7 (query) / 9.3 (assoc) MB per model | 19.5 / 22.9. Halved, not at origin/main's level. |
| one-model lifecycle debug build at most 1,300 MB | 1,804. The program's fixed cost (stdlib, the lifecycle harness) dominates; no preload or writer path is involved. |

What is left per model, from the LLVM IR of a 10-model program: about 125
`Builder(Model)` instance methods (`where`, `chain_copy`, `select`,
`chunked_select`, the eager-load join resolvers `add_through_eager_load_join`
and `add_polymorphic_as_eager_load_join`, `association_restrictions`),
`Executor::List(Model)#run` (about 8,000 IR lines), one setter per column
(about 1,500 IR lines each), and about 64 generated methods for a model with
a `belongs_to` and a `has_many` (the `_autosave_*` and `_validate_associated_*`
families are 18 of them). Declaring a plain model costs about 2.8 MB before any call; a
`belongs_to` plus a `has_many` adds about 3.7 MB.

The largest remaining lever found: `Model.transaction` and
`Grant::Transaction.run` yield, so every call site (`save` has two per
model, each about 9,900 IR lines) carries its own copy of the transaction
machinery. Taking the block as a `Proc` in `Transaction.run` would share one
copy. The same change on the two chunked terminals cut the debug build of
`association_regressions_spec.cr` by 16%.

## Runtime guardrail

`bench/lifecycle_bench.cr` (sqlite, release, 2,000 iterations, 5 rounds, two
runs each, grant variant). Best mean of the two runs, microseconds, and bytes
allocated per operation:

| Operation | Before | After | Mean ratio | Bytes ratio |
| --- | ---: | ---: | ---: | ---: |
| build (no database) | 1.47 | 1.38 | 0.94 | 1.00 |
| create | 30.84 | 29.53 | 0.96 | 1.00 |
| find by id | 11.96 | 11.72 | 0.98 | 1.01 |
| page of 100 by index | 131.16 | 126.62 | 0.97 | 1.00 |
| load all 2000 rows | 5,861.69 | 5,588.20 | 0.95 | 1.00 |
| count | 65.81 | 63.53 | 0.97 | 1.03 |
| load and update | 28.37 | 29.43 | 1.04 | 1.01 |
| load and destroy | 32.51 | 32.08 | 0.99 | 1.01 |

Every operation stays within 1.1x on mean and allocation.

## Commands

All compiles go through the machine's compile limiter. From the repository
root:

```sh
export CRYSTAL_SLOT=/path/to/crystal-slot          # or leave "crystal-slot" on PATH
export CRYSTAL_BIN=crystal-alpha

# one probe: workload query|assoc|assoc_one|assoc_none|none, count, semantic|debug
scripts/compile_memory.py probe assoc_one 200 semantic

# per-model slope (MB per model between two counts)
scripts/compile_memory.py slope query 10 200

# any file
BENCH_ADAPTER=sqlite scripts/compile_memory.py file bench/lifecycle_bench.cr debug
CURRENT_ADAPTER=sqlite scripts/compile_memory.py file spec/grant/associations/association_regressions_spec.cr debug

# every limit above, nonzero exit when one is missed
scripts/compile_memory.py check
```

The runtime guardrail:

```sh
BENCH_ADAPTER=sqlite crystal-slot crystal-alpha build --release bench/lifecycle_bench.cr -o /tmp/lifecycle
BENCH_DATABASE_URL=sqlite3:/tmp/lifecycle.db /tmp/lifecycle --iterations 2000 --rounds 5 --label after --json /tmp/after.json
```

The investigation this work follows, with its ablations and generator
scripts, is `parity-audit-2026-09-28/evidence/compile_memory/codex_report.md`.

## PERF03 round 1: shared query work and measured budgets

PERF03 kept the public block APIs yield-based and changed only Grant's internal
save transaction route. `Transaction.run_without_result` captures the save
body as a typed `Proc(Nil)`, so the transaction runner is shared. The query
list executor now passes row hydration through a fixed-signature loader to one
non-generic cursor runner. Association restriction discovery and replay moved
to one non-generic resolver that takes the model name and relation state as
values. A PostgreSQL boolean query compatibility fix was needed first because
the starting commit did not compile the lifecycle benchmark with its locked
`db` dependency; the SQLite path used for runtime measurements was unchanged.

The first row is the PERF03 starting measurement supplied for `da1e061`. Later
rows are the before/after measurements from each attempted code change. The
column setter experiment is included for transparency and was reverted because
it did not produce a reliable compile improvement.

| Step | Query slope MB/model | Association slope MB/model | `assoc_one` 200 semantic MB | Lifecycle debug MB | Association regression debug MB |
| --- | ---: | ---: | ---: | ---: | ---: |
| PERF03 starting point | 19.5 | 22.9 | 1,690.0 | 1,804.0 | 6,887.0 |
| Transaction Proc path (`97d8194`) | 19.58 → 19.70 | 22.75 → 22.73 | 1,632.8 → 1,661.8 | 1,863.8 → 1,845.3 | 6,696.5 → 6,230.2 |
| Shared list cursor runner (`c1b8abe`) | 19.70 → 19.22 | 22.73 → 22.42 | 1,661.8 → 1,632.8 | 1,845.3 → 1,871.4 | 6,230.2 → 5,770.7 |
| Shared association restriction resolver (`2630a6e`) | 19.22 → 18.48 | 22.42 → 21.79 | 1,632.8 → 1,632.8 | 1,871.4 → 1,841.5 | 5,770.7 → 5,819.2 |
| Column dirty-assignment experiment (`89209a4`, reverted) | 18.48 → 18.65 | 21.79 → 21.62 | 1,632.8 → 1,614.7 | 1,841.5 → 1,828.1 | 5,819.2 → 6,277.1 |
| Final source, budget measurement | 18.6 | 21.8 | 1,711.8 | 1,851.5 | 6,255.1 |

The retained changes lowered the association regression debug build by about
9% from the starting measurement and lowered the semantic slopes by about 5%.
The one-query associated declaration probe and lifecycle debug build did not
improve reliably. Final budget inputs are the maximum of three complete
`scripts/compile_memory.py check` runs; the corresponding 5% limits are in
[`bench/budgets.json`](../bench/budgets.json). Every command and source revision
is recorded in [`docs/performance/perf03_measurements.jsonl`](performance/perf03_measurements.jsonl).

### PERF03 targets

| Target | Final measured value | Status |
| --- | ---: | --- |
| `assoc_one` 200 semantic at most 1,600 MB | 1,711.8 MB | Not met. Most of this probe's cost is still model declaration. |
| Query semantic slope at most 7.7 MB/model | 18.6 MB/model | Not met. The generic builder remains the largest per-model body. |
| Association semantic slope at most 9.3 MB/model | 21.8 MB/model | Not met. Association declarations still add typed relation and callback code. |
| One-model lifecycle debug at most 1,300 MB | 1,851.5 MB | Not met. The fixed Grant, stdlib, and benchmark harness cost remains. |

There is no separate PERF03 target for `association_regressions_spec.cr`; its
6,255.1 MB peak is lower than the 6,887 MB starting measurement and is gated
at the final value plus 5% headroom.

### Remaining IR cost

The final query IR probe used ten generated scalar-query models. The exact
command and counts are in the measurement log. It emitted a 105,378,769-byte
LLVM IR file and contained 1,330 `Builder(Model)` function definitions across
the ten models (about 133 per model, with 195,730 function-body lines). The
list executor still emitted 80 model-specific functions (8 per model, 15,660
body lines total). The cursor loop itself appeared once as
`SharedListRunner#run` (2,377 body lines). The association restriction resolver
and its helpers appeared as five functions and 1,081 body lines total.

This confirms why the slope targets remain unmet: the shared runner removed the
per-model database cursor loop, but each model still owns a typed `Builder`
stack and typed result-cache/hydration entrypoints. Moving more builder state,
SQL planning, or callback methods requires preserving each model's concrete
relation return type, association scope behavior, and callback registration.
The setter experiment's final IR opportunity was not retained because its
compile peaks did not improve consistently and the association regression
measurement increased.

`_autosave_*` and `_validate_associated_*` methods remain generated per
association. They participate in per-association validation and save callbacks;
no shared replacement was measured and verified in PERF03. Optional feature
requires also remain unchanged: prior reachability ablations either broke
`require "grant"` transitive behavior or saved too little to justify changing
the entrypoint surface.

### PERF03 runtime guardrail

Three release runs averaged 2,000 SQLite lifecycle iterations and five
leak-check rounds. The baseline was captured at `7881cdf` after the typed
PostgreSQL boolean prerequisite; this changed no SQLite query path. Every mean
and allocation ratio stayed within the required 1.05x baseline.

| Operation | Baseline mean µs | Final mean µs | Mean ratio | Baseline bytes/op | Final bytes/op | Bytes ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| build (no database) | 0.540 | 0.553 | 1.024 | 1,167.8 | 1,164.9 | 0.997 |
| create | 40.755 | 37.760 | 0.927 | 8,942.8 | 8,941.7 | 1.000 |
| find by id | 3.967 | 4.126 | 1.040 | 1,629.5 | 1,645.3 | 1.010 |
| page of 100 by index | 32.933 | 31.421 | 0.954 | 27,177.3 | 27,115.3 | 0.998 |
| load all 2000 rows | 1,078.564 | 975.693 | 0.905 | 1,288,479.1 | 1,288,648.0 | 1.000 |
| count | 64.775 | 65.382 | 1.009 | 3,304.1 | 3,343.6 | 1.012 |
| load and update | 30.155 | 28.994 | 0.961 | 10,652.9 | 10,666.2 | 1.001 |
| load and destroy | 34.175 | 28.772 | 0.842 | 3,008.8 | 3,027.8 | 1.006 |

The shared budgets and checker are described in
[`docs/PERFORMANCE_BUDGETS.md`](PERFORMANCE_BUDGETS.md).


## PERF03 round 2: shared query planning and association callbacks

Round two started at `6184649` with 18.5 MB/model query slope, 21.9 MB/model
association slope, and 121 `Query::Builder(Model)` definitions totaling
18,896 IR body lines per model. The retained work moved relation state,
copy/merge operations, predicate planning, scope collection, eager-load
planning, and association callback work into shared non-generic helpers.
`Builder(Model)` remains the typed facade and preserves its existing concrete
return types, scopes, association scopes, and `Enumerable(Model)` behavior.
Typed hydration and terminal paths still depend on `Model`.

### Incremental Builder measurements

Each query step used the same 10-to-200 semantic slope probes and the generated
ten-model query LLVM IR fixture. The `IR` column is function definitions and
body lines per model. A small increase in one slope is measurement variance;
the per-step records and final calibration samples are in the JSONL log.

| Query step | Query slope MB/model | Association slope MB/model | Builder IR definitions/body lines per model |
| --- | ---: | ---: | ---: |
| Round-two start | 18.50 | 21.90 | 121 / 18,896 |
| Relation state and unscope | 18.50 → 16.98 | 21.90 → 20.39 | 121 / 18,896 → 135 / 5,715 |
| Oversized-IN index | 16.98 → 16.88 | 20.39 → 19.70 | 135 / 5,715 → 135 / 5,443 |
| Nil-aware key-list predicate | 16.88 → 16.80 | 19.70 → 19.50 | 135 / 5,443 → 135 / 5,299 |
| Association condition planner | 16.80 → 16.63 | 19.50 → 19.58 | 135 / 5,299 → 130 / 4,678 |
| Eager-load join planning | 16.63 → 16.53 | 19.58 → 19.51 | 130 / 4,678 → 130 / 4,444 |
| Relation component merge | 16.53 → 16.34 | 19.51 → 19.32 | 130 / 4,444 → 129 / 4,030 |
| Foreign-relation staging | 16.34 → 16.08 | 19.32 → 19.06 | 129 / 4,030 → 114 / 3,690 |
| Raw WHERE registration merge | 16.08 → 16.05 | 19.06 → 19.03 | 114 / 3,690 → 113 / 3,544 |
| Scope equality collection | 16.05 → 16.05 | 19.03 → 18.83 | 113 / 3,544 → 111 / 3,307 |
| Relation order merge | 16.05 → 16.05 | 18.83 → 18.94 | 111 / 3,307 → 109 / 3,238 |
| Named-scope relation merge | 16.05 → 16.05 | 18.94 → 18.86 | 109 / 3,238 → 109 / 3,238 |

The three-run final calibration reports maxima of 16.1 MB/model query slope and
18.9 MB/model association slope. Relative to round-two start, Builder IR body
lines fell 82.9% (18,896 to 3,238); definitions fell from 121 to 109 per model.

### Generated association callbacks

The autosave and associated-validation implementations now share their record
collection, validation, and error-import logic. The generated typed methods
remain as small accessors so association reflection and concrete model types
stay intact. The ten-model association IR probe measured:

| Generated family | Before: definitions / body lines per model | After: definitions / body lines per model |
| --- | ---: | ---: |
| `_autosave_*` | 5 / 670 | 5 / 133 |
| `_validate_associated_*` | 4 / 388 | 4 / 139 |

The definition count is unchanged, but these bodies are 80.1% and 64.2% smaller,
respectively. The shared implementation preserves the existing association
callbacks; the required final grouped SQLite suite validates the complete change.

### Round-two compile results and targets

The RSS values below compare the round-two start commit with the maximum of
three final samples on Darwin with crystal-alpha 1.21.0. The association
regression spec has no standalone target; its result is shown to track the
improvement. The exact commands and samples are in the measurement ledger.

| Probe | Round-two start MB | Final max MB | Target | Result |
| --- | ---: | ---: | ---: | --- |
| Query slope, 10–200 models | 18.5 | 16.1 | ≤ 7.7 MB/model | Missed |
| Association slope, 10–200 models | 21.9 | 18.9 | ≤ 9.3 MB/model | Missed |
| `assoc_one`, 200 models | 1,632.8 | 1,599.0 | ≤ 1,600 MB | Met by 1.0 MB |
| Lifecycle benchmark debug | 1,836.4 | 1,846.9 | ≤ 1,300 MB | Missed; +10.5 MB vs start |
| Association regression spec debug | 6,391.8 | 5,179.1 | No separate target | Reduced 19.0% |

The measured final slope remains above target, so this is not a claim that the
generic cost has reached a hard theoretical floor. The ten-model LLVM IR still
contains 109 Builder definitions and 3,238 body lines per model. Its largest
remaining typed bodies are `select` (232 lines), `collapse_or_fields!` (158),
`chunked_select` and `select_single` (142 each), `expand_where_column_name`
(138), `each_in_chunk` (135), `add_association_condition` (123),
`add_eager_load_join` (118), `add_common_table!` (103), and
`unscope_where_columns!` (93). These paths still construct model-specific
relations, use model reflection or column types, or return/hydrate concrete
`Model` values. A further reduction needs to separate those typed boundaries
without changing relation, scope, or terminal behavior.

### Round-two runtime comparison

Each final value is the average of three SQLite release runs, each with 2,000
iterations and five rounds. Ratios compare the round-one baseline at
`7881cdf` with the round-two final mean and allocation average. All three-run aggregate means and bytes/op are within 1.05×. Load-all is the
narrowest aggregate mean at 1.047×: its three run means were 1,216.250,
1,101.528, and 1,069.372 µs, so the highest sample was 1.128× the round-one
baseline. CI uses a loose time multiplier and a tight allocation limit as
documented in
[`PERFORMANCE_BUDGETS.md`](PERFORMANCE_BUDGETS.md).

| Operation | Round-one mean µs | Round-two mean µs | Mean ratio | Round-one bytes/op | Round-two bytes/op | Bytes ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| build (no database) | 0.540 | 0.514 | 0.952 | 1,167.8 | 1,168.4 | 1.000 |
| create | 40.755 | 40.305 | 0.989 | 8,942.8 | 8,941.2 | 1.000 |
| find by id | 3.967 | 4.040 | 1.018 | 1,629.5 | 1,646.0 | 1.010 |
| page of 100 by index | 32.933 | 30.796 | 0.935 | 27,177.3 | 27,202.4 | 1.001 |
| load all 2,000 rows | 1,078.564 | 1,129.050 | 1.047 | 1,288,479.1 | 1,289,128.9 | 1.001 |
| count | 64.775 | 65.450 | 1.010 | 3,304.1 | 3,338.5 | 1.010 |
| load and update | 30.155 | 29.021 | 0.962 | 10,652.9 | 10,669.4 | 1.002 |
| load and destroy | 34.175 | 34.737 | 1.016 | 3,008.8 | 3,025.1 | 1.005 |

The measured, per-platform budgets and the Linux calibration-only CI behavior
are described in [`PERFORMANCE_BUDGETS.md`](PERFORMANCE_BUDGETS.md).
