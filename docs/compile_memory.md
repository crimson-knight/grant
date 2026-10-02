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
`crystal build`.

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
