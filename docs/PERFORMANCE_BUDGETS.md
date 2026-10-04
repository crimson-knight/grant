# Performance budgets

Grant gates compile memory and SQLite lifecycle performance in CI. Measured
values, limits, source revisions, and the commands that produced them live in
[`bench/budgets.json`](../bench/budgets.json) and
[`docs/performance/perf03_measurements.jsonl`](performance/perf03_measurements.jsonl).

## What is budgeted

The compile checker runs five serial probes with an empty `CRYSTAL_CACHE_DIR`:

- semantic RSS for 200 associated models with one query;
- debug RSS for the lifecycle benchmark and the association regression spec;
- semantic query and association slopes from 10 to 200 models.

No probe is skipped or scaled on the 16 GB Ubuntu runner. The largest observed
debug probe is 6,887 MB, below half the runner's memory. Linux probes use
`--link-flags=-Wl,--no-export-dynamic`, as in `scripts/spec-groups.sh`.

The runtime checker covers every Grant operation in
[`bench/lifecycle_bench.cr`](../bench/lifecycle_bench.cr): object build, create,
find, indexed page, load-all, count, update, and destroy. It checks both mean
microseconds and allocated bytes per operation.

## Platform and toolchain blocks

`bench/budgets.json` selects a separate block using `platform.system()` and the
selected compiler's `--version`. The key includes the OS, compiler flavor, and
version, such as `darwin-crystal-alpha-1.21.0` or
`linux-crystal-1.21.0`. A missing or calibration-only block makes `check` fail
with a clear error; a result from one platform is never used as another
platform's budget.

The Darwin block is measured with crystal-alpha 1.21.0. The Linux stock Crystal
1.21.0 block remains `calibration-required` until a real GitHub runner sample
is reviewed and committed. CI says when it is in calibration mode, runs the
measurements without enforcing limits, and uploads both raw measurement JSON
files as an artifact. When a measured Linux block is added, the same workflow
automatically switches to enforcement.

## Why timing and bytes have different CI limits

Compile RSS is stable enough to use a 5% limit above the highest of three
measurements. The runtime values come from the Grant-only SQLite variant with
2,000 records and five leak-check rounds. Local limits add 10% above the highest
of three observed means and allocations. On shared CI runners, CPU scheduling
and filesystem activity make timing noisy, so CI allows 1.5 times the measured
maximum mean. Bytes per operation are less affected by runner contention, so CI
keeps them within 5% of the maximum measured allocation.

## Measure locally

Use the locked dependencies, Crystal Alpha 1.21.0, and the machine's
`crystal-slot` limiter. Set `CRYSTAL_SLOT` to its path if it is not on `PATH`.

```sh
shards-alpha install --frozen
export CRYSTAL_SLOT=/path/to/crystal-slot
export CRYSTAL_BIN=crystal-alpha
export CRYSTAL_WORKERS=1

# Enforce the selected platform's compile budgets.
python3 scripts/compile_memory.py check --json-output /tmp/perf03-compile-check.json

# Take a non-enforcing compile calibration and print a paste-ready JSON block.
python3 scripts/compile_memory.py calibrate --runs 3 > /tmp/perf03-compile-calibration.json

# Build and run the lifecycle benchmark, then check the selected platform's limits.
BENCH_ADAPTER=sqlite "$CRYSTAL_SLOT" crystal-alpha build --release bench/lifecycle_bench.cr -o /tmp/grant-lifecycle
BENCH_DATABASE_URL=sqlite3:/tmp/grant-lifecycle.db /tmp/grant-lifecycle \
  --iterations 2000 --rounds 5 --grant-only --label perf03-builder \
  --json /tmp/grant-lifecycle.json
python3 scripts/check_runtime_budget.py check /tmp/grant-lifecycle.json --mode local

# Or let the runtime calibrator build, run, and print the paste-ready block.
BENCH_ADAPTER=sqlite python3 scripts/check_runtime_budget.py calibrate --runs 3 \
  > /tmp/perf03-runtime-calibration.json
```

On Linux, include `--link-flags=-Wl,--no-export-dynamic` on a manual lifecycle
build. The calibrators add the appropriate Linux linker flag automatically.
Calibration never enforces current limits; it runs the measurements and prints
the maximum of its samples, measured values, limits with stated headroom, and
commands/environment to reproduce them. Review this JSON before copying its
compile or runtime block into the matching platform budget. The compile probe
uses one Crystal worker because the local crystal-alpha scheduler stalled on
the 200-model association slope with its default worker count. CI also sets one
worker so the probe has the same execution shape.

Linux remains in calibration mode until a measured Linux block is reviewed.
That workflow announces the mode in its log and step summary, runs the compile
probes once (their RSS is stable) and the runtime benchmark three times without
enforcement, then uploads the compile/runtime JSON as a workflow artifact. Once the Linux block is marked `measured`, CI enforces it
and continues uploading the raw check and lifecycle result JSON.

## Raise a budget

A budget change needs a measured explanation. Measure the same workload with
the same platform and toolchain, append the before/after values and exact
commands to `docs/performance/perf03_measurements.jsonl`, and set `measured_*`
and limit values in the appropriate platform block using the documented
headroom. Update the PERF03 results in `docs/compile_memory.md` when a compile
result changes.

Every PR that changes `bench/budgets.json` must say which compile probe or
lifecycle operation grew, by how much, and why the extra cost is needed. Include
the before/after measurement and command. A budget change without that
explanation does not establish that the additional cost is acceptable.
