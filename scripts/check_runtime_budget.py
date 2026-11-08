#!/usr/bin/env python3
"""Check lifecycle_bench.cr JSON or calibrate platform-specific runtime limits."""
import argparse
import json
import math
import os
import platform
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

from performance_budget_platform import BudgetSelectionError, crystal_binary, platform_key, select_budget


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUDGETS = ROOT / "bench" / "budgets.json"
SLOT = os.environ.get("CRYSTAL_SLOT", "crystal-slot")
VARIANT = "perf03-builder"
ITERATIONS = 2000
ROUNDS = 5


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("cannot read JSON result %s: %s" % (path, error)) from error


def check(result_path: Path, budgets_path: Path, mode: str) -> int:
    key, platform_budget = select_budget(budgets_path)
    runtime = platform_budget.get("runtime")
    if not runtime:
        raise BudgetSelectionError("performance budget for %s has no runtime limits" % key)

    conditions = runtime.get("conditions")
    if not isinstance(conditions, dict):
        raise BudgetSelectionError("runtime budget for %s has no measurement conditions; run calibrate and add its block" % key)
    expected_workers = conditions.get("CRYSTAL_WORKERS")
    if expected_workers is None:
        raise BudgetSelectionError("runtime budget for %s does not record CRYSTAL_WORKERS" % key)
    current_conditions = {
        "adapter": os.environ.get("BENCH_ADAPTER", "sqlite"),
        "CRYSTAL_WORKERS": os.environ.get("CRYSTAL_WORKERS", "1"),
    }
    mismatched_conditions = [
        name for name, value in current_conditions.items()
        if str(conditions.get(name)) != value
    ]
    if mismatched_conditions:
        details = ", ".join(
            "%s measured=%s current=%s" % (name, conditions.get(name), current_conditions[name])
            for name in mismatched_conditions
        )
        raise BudgetSelectionError("runtime budget for %s has different measurement conditions: %s" % (key, details))

    result = read_json(result_path)
    expected_variant = runtime["variant"]
    variants = [variant for variant in result["list_of_variants"] if variant["variant"] == expected_variant]
    if len(variants) != 1:
        print("expected exactly one %r variant in %s" % (expected_variant, result_path), file=sys.stderr)
        return 1

    measured = {operation["operation"]: operation for operation in variants[0]["list_of_operations"]}
    expected = runtime["operations"]
    missing = sorted(set(expected) - set(measured))
    unexpected = sorted(set(measured) - set(expected))
    if missing or unexpected:
        if missing:
            print("missing budgeted lifecycle operations: " + ", ".join(missing), file=sys.stderr)
        if unexpected:
            print("operations need budgets before this bench can pass: " + ", ".join(unexpected), file=sys.stderr)
        return 1

    failures = []
    for name, budget in expected.items():
        operation = measured[name]
        mean = operation["mean_microseconds"]
        bytes_per_operation = operation["bytes_per_operation"]
        mean_limit = budget[mode]["mean_limit_microseconds"]
        bytes_limit = budget[mode]["bytes_limit_per_operation"]
        passed = mean <= mean_limit and bytes_per_operation <= bytes_limit
        state = "PASS" if passed else "FAIL"
        print(
            "%s %-26s mean %.3f / %.3f µs; bytes %.1f / %.1f B/op"
            % (state, name, mean, mean_limit, bytes_per_operation, bytes_limit),
            flush=True,
        )
        if not passed:
            failures.append(name)

    if failures:
        print("over the %s runtime budget for %s: %s" % (mode, key, ", ".join(failures)), file=sys.stderr)
        return 1
    return 0


def calibrate(budgets_path: Path, runs: int, iterations: int, rounds: int) -> None:
    if runs < 1 or iterations < 1 or rounds < 1:
        raise ValueError("--runs, --iterations, and --rounds must be positive")

    configuration = read_json(budgets_path).get("runtime_probe", {})
    variant_name = configuration.get("variant", VARIANT)
    key = platform_key()
    crystal = crystal_binary()
    env = dict(os.environ)
    env["BENCH_ADAPTER"] = "sqlite"
    env.setdefault("CRYSTAL_WORKERS", "1")
    bench = ROOT / "bench" / "lifecycle_bench.cr"
    link_flags = ["--link-flags=-Wl,--no-export-dynamic"] if platform.system() == "Linux" else []

    with tempfile.TemporaryDirectory(prefix="grant-runtime-calibration-") as temporary:
        temp = Path(temporary)
        binary = temp / "lifecycle_bench"
        build_command = ([SLOT] if SLOT else []) + [crystal, "build", "--release", "--no-color", *link_flags, str(bench), "-o", str(binary)]
        build_env = dict(env, CRYSTAL_CACHE_DIR=str(temp / "crystal-cache"))
        print("building lifecycle benchmark for %s" % key, file=sys.stderr, flush=True)
        subprocess.run(build_command, cwd=ROOT, env=build_env, check=True)

        raw_runs = []
        for run in range(1, runs + 1):
            result_path = temp / ("lifecycle-%d.json" % run)
            db_path = temp / ("lifecycle-%d.sqlite" % run)
            command = [str(binary), "--iterations", str(iterations), "--rounds", str(rounds), "--grant-only", "--label", variant_name, "--json", str(result_path)]
            database_url = "sqlite3:" + str(db_path)
            run_env = dict(env, BENCH_DATABASE_URL=database_url)
            subprocess.run(command, cwd=ROOT, env=run_env, check=True, stdout=subprocess.DEVNULL)
            raw = read_json(result_path)
            raw_runs.append({
                "run": run,
                "command": shlex.join(command),
                "environment": {"BENCH_DATABASE_URL": database_url, "CRYSTAL_WORKERS": env["CRYSTAL_WORKERS"]},
                "result": raw,
            })
            print("completed runtime calibration run %d/%d" % (run, runs), file=sys.stderr, flush=True)

    by_operation = {}
    for raw in raw_runs:
        variants = [variant for variant in raw["result"]["list_of_variants"] if variant["variant"] == variant_name]
        if len(variants) != 1:
            raise ValueError("calibration run %d did not contain exactly one %r variant" % (raw["run"], variant_name))
        for operation in variants[0]["list_of_operations"]:
            by_operation.setdefault(operation["operation"], []).append(operation)

    operations = {}
    for name, samples in by_operation.items():
        means = [sample["mean_microseconds"] for sample in samples]
        allocations = [sample["bytes_per_operation"] for sample in samples]
        max_mean = max(means)
        max_bytes = max(allocations)
        operations[name] = {
            "measured_mean_microseconds": round(sum(means) / len(means), 6),
            "maximum_observed_mean_microseconds": round(max_mean, 6),
            "measured_bytes_per_operation": round(sum(allocations) / len(allocations), 3),
            "maximum_observed_bytes_per_operation": round(max_bytes, 3),
            "local": {
                "mean_limit_microseconds": round(max_mean * 1.10, 3),
                "bytes_limit_per_operation": math.ceil(max_bytes * 1.10),
            },
            "ci": {
                "mean_limit_microseconds": round(max_mean * 1.50, 3),
                "bytes_limit_per_operation": math.ceil(max_bytes * 1.05),
            },
        }

    calibration_environment = [
        "BENCH_ADAPTER=sqlite",
        "CRYSTAL_BIN=" + crystal,
        "CRYSTAL_SLOT=" + SLOT,
        "CRYSTAL_WORKERS=" + env["CRYSTAL_WORKERS"],
    ]
    link_flags_text = " --link-flags=-Wl,--no-export-dynamic" if link_flags else ""
    result = {
        "platform_key": key,
        "runtime": {
            "adapter": "sqlite",
            "variant": variant_name,
            "iterations": iterations,
            "rounds": rounds,
            "runs_averaged": runs,
            "conditions": {
                "adapter": "sqlite",
                "CRYSTAL_WORKERS": env["CRYSTAL_WORKERS"],
            },
            "local_headroom_percent": 10,
            "ci_time_multiplier": 1.5,
            "ci_bytes_headroom_percent": 5,
            "operations": operations,
            "commands": {
                "calibrate": " ".join(calibration_environment + ["python3", "scripts/check_runtime_budget.py", "calibrate", "--runs", str(runs), "--iterations", str(iterations), "--rounds", str(rounds)]),
                "build": "BENCH_ADAPTER=sqlite CRYSTAL_WORKERS=%s \"${CRYSTAL_SLOT:-crystal-slot}\" \"$CRYSTAL_BIN\" build --release --no-color%s bench/lifecycle_bench.cr -o /tmp/grant-lifecycle" % (env["CRYSTAL_WORKERS"], link_flags_text),
                "run": "BENCH_DATABASE_URL=sqlite3:/tmp/grant-lifecycle.sqlite /tmp/grant-lifecycle --iterations %d --rounds %d --grant-only --label %s --json /tmp/perf03-lifecycle.json" % (iterations, rounds, variant_name),
                "calibration_build_actual": shlex.join(build_command),
            },
            "environment": {
                "BENCH_ADAPTER": "sqlite",
                "CRYSTAL_BIN": crystal,
                "CRYSTAL_SLOT": SLOT,
                "CRYSTAL_WORKERS": env["CRYSTAL_WORKERS"],
            },
        },
        "raw_runs": raw_runs,
    }
    print(json.dumps(result, indent=2, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check_parser = subparsers.add_parser("check", help="enforce the selected platform's budget")
    check_parser.add_argument("result", type=Path, help="JSON output written by lifecycle_bench.cr")
    check_parser.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS)
    check_parser.add_argument("--mode", choices=("local", "ci"), default="local")

    calibrate_parser = subparsers.add_parser("calibrate", help="run lifecycle measurements and print paste-ready JSON")
    calibrate_parser.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS)
    calibrate_parser.add_argument("--runs", type=int, default=3)
    calibrate_parser.add_argument("--iterations", type=int)
    calibrate_parser.add_argument("--rounds", type=int)

    args = parser.parse_args()
    try:
        if args.command == "check":
            return check(args.result, args.budgets, args.mode)
        configuration = read_json(args.budgets).get("runtime_probe", {})
        iterations = args.iterations if args.iterations is not None else configuration.get("iterations", ITERATIONS)
        rounds = args.rounds if args.rounds is not None else configuration.get("rounds", ROUNDS)
        calibrate(args.budgets, args.runs, iterations, rounds)
        return 0
    except (BudgetSelectionError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
