# Performance budgets

Grant's compile and runtime checks are part of the normal pull request gate.
The limits live in [`bench/budgets.json`](../bench/budgets.json); the measured
inputs, source revisions, and commands are recorded in
[`docs/performance/perf03_measurements.jsonl`](performance/perf03_measurements.jsonl).

## What CI measures

The compile gate uses an empty `CRYSTAL_CACHE_DIR` and records peak RSS in
decimal MB with Crystal 1.21.0. It checks the 200-model associated declaration,
the lifecycle benchmark's one-model debug build, the association regression
spec's debug build, and semantic query and association slopes from 10 to 200
models. The slope probes compile both endpoints. The probes run serially; none
are skipped because the largest measured debug probe is below the 16 GB Ubuntu
runner's capacity. Linux builds use
`--link-flags=-Wl,--no-export-dynamic`, matching `scripts/spec-groups.sh`.

The runtime gate runs the SQLite Grant variant of
[`bench/lifecycle_bench.cr`](../bench/lifecycle_bench.cr) with 2,000 records and
five leak-check rounds. It checks every operation's mean microseconds and heap
bytes per operation. The local mean limit is 10% above the highest mean from
the three runs used to set the budget; the local byte limit is 10% above the
highest observed allocation. CI permits mean time up to 1.5 times the measured
three-run average because shared-runner scheduling and filesystem activity add
timing noise. CI keeps allocation headroom to 5% above the highest observed
run, which remains a tight and repeatable signal.

## Measure locally

Use Crystal Alpha 1.21.0, the frozen shard lock, and the machine's `crystal-slot`
limiter. Set `CRYSTAL_SLOT` to the limiter path if it is not on `PATH`.

```sh
shards-alpha install --frozen
CRYSTAL_SLOT=/path/to/crystal-slot CRYSTAL_BIN=crystal-alpha python3 scripts/compile_memory.py check

BENCH_ADAPTER=sqlite CRYSTAL_SLOT=/path/to/crystal-slot crystal-alpha build --release bench/lifecycle_bench.cr -o /tmp/grant-lifecycle
BENCH_DATABASE_URL=sqlite3:/tmp/grant-lifecycle.db /tmp/grant-lifecycle \
  --iterations 2000 --rounds 5 --grant-only --label perf03-builder \
  --json /tmp/grant-lifecycle.json
python3 scripts/check_runtime_budget.py /tmp/grant-lifecycle.json --mode local
```

On Linux, add `--link-flags=-Wl,--no-export-dynamic` to the lifecycle build.
CI uses the pinned checkout and Crystal install actions already used by
[`spec.yml`](../.github/workflows/spec.yml), installs shards with
`--frozen`, and runs the same compile and runtime checkers.

For a single compile measurement, use `scripts/compile_memory.py probe`,
`slope`, or `file`. Each invocation still uses the configured limiter and a
fresh compiler cache.

## Raise a budget

A budget change needs measured evidence from the same workload and toolchain.
Run the relevant probe or benchmark, append its before/after values and exact
command to `docs/performance/perf03_measurements.jsonl`, then set the recorded
measurement and limit in `bench/budgets.json` using the stated headroom. Update
the PERF03 results in `docs/compile_memory.md` when the compile result changes.

Every pull request that changes `bench/budgets.json` must say which operation
or compile probe grew, by how much, and why the growth is needed. Include the
before/after measurement and command. A budget change without an explanation
does not establish that the extra cost is acceptable.
