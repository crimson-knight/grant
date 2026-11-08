#!/usr/bin/env python3
"""Resolve the performance budget for this operating system and Crystal toolchain."""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUDGETS = ROOT / "bench" / "budgets.json"


class BudgetSelectionError(RuntimeError):
    pass


def crystal_binary() -> str:
    return os.environ.get("CRYSTAL_BIN", "crystal-alpha")


def platform_key() -> str:
    system = platform.system().lower()
    executable = crystal_binary()
    resolved = shutil.which(executable) or executable
    try:
        result = subprocess.run([resolved, "--version"], check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise BudgetSelectionError("cannot identify Crystal toolchain using %r --version: %s" % (executable, error)) from error

    version_match = re.search(r"\bCrystal\s+([0-9]+\.[0-9]+\.[0-9]+)\b", result.stdout + result.stderr)
    if version_match is None:
        raise BudgetSelectionError("cannot parse Crystal version from %r --version output" % executable)

    flavor = "crystal-alpha" if "alpha" in Path(executable).name.lower() else "crystal"
    return "%s-%s-%s" % (system, flavor, version_match.group(1))


def select_budget(budgets_path: Path = DEFAULT_BUDGETS) -> tuple[str, dict]:
    budgets_path = Path(budgets_path)
    key = platform_key()
    try:
        data = json.loads(budgets_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BudgetSelectionError("cannot read budget file %s: %s" % (budgets_path, error)) from error

    budgets = data.get("platform_budgets", {})
    if key not in budgets:
        available = ", ".join(sorted(budgets)) or "none"
        raise BudgetSelectionError("no performance budget for %s (available: %s); calibrate this platform/toolchain and add its block to %s" % (key, available, budgets_path))

    block = budgets[key]
    if block.get("status") != "measured":
        note = block.get("note", "no measured budget is configured")
        raise BudgetSelectionError("performance budget for %s is not enforceable: %s" % (key, note))
    return key, block


def status(budgets_path: Path = DEFAULT_BUDGETS) -> tuple[str, str, str]:
    budgets_path = Path(budgets_path)
    key = platform_key()
    try:
        data = json.loads(budgets_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BudgetSelectionError("cannot read budget file %s: %s" % (budgets_path, error)) from error

    budgets = data.get("platform_budgets", {})
    block = budgets.get(key)
    if block is None:
        available = ", ".join(sorted(budgets)) or "none"
        raise BudgetSelectionError("no performance budget for %s (available: %s); calibrate this platform/toolchain and add its block to %s" % (key, available, budgets_path))
    return key, block.get("status", "unset"), block.get("note", "")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("key", "status"))
    parser.add_argument("--budgets", type=Path, default=DEFAULT_BUDGETS)
    args = parser.parse_args()

    try:
        if args.command == "key":
            print(platform_key())
        else:
            key, state, note = status(args.budgets)
            print("%s %s%s" % (key, state, (": " + note) if note else ""))
    except BudgetSelectionError as error:
        print(str(error), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
