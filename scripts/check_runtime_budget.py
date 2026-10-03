#!/usr/bin/env python3
"""Check lifecycle_bench.cr JSON against bench/budgets.json."""
import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", help="JSON output written by lifecycle_bench.cr")
    parser.add_argument("--budgets", default=str(ROOT / "bench" / "budgets.json"))
    parser.add_argument("--mode", choices=("local", "ci"), default="local")
    args = parser.parse_args()

    budgets = json.loads(Path(args.budgets).read_text(encoding="utf-8"))
    runtime = budgets["runtime"]
    result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    expected_variant = runtime["variant"]
    variants = [variant for variant in result["list_of_variants"] if variant["variant"] == expected_variant]
    if len(variants) != 1:
        print("expected exactly one %r variant in %s" % (expected_variant, args.result), file=sys.stderr)
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
        mean_limit = budget[args.mode]["mean_limit_microseconds"]
        bytes_limit = budget[args.mode]["bytes_limit_per_operation"]
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
        print("over the %s runtime budget: %s" % (args.mode, ", ".join(failures)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
