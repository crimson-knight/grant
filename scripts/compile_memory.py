#!/usr/bin/env python3
"""Compile-memory probe for Grant: generates N models and measures peak RSS.

Usage (from the repo root, one compile at a time through crystal-slot):

  scripts/compile_memory.py probe <query|assoc|assoc_one|assoc_none|none> <count> [semantic|debug]
  scripts/compile_memory.py file <path.cr> [semantic|debug]
  scripts/compile_memory.py slope <query|assoc> [low] [high]
  scripts/compile_memory.py check [--json-output <path>]

`query` queries every model once, `assoc` adds a belongs_to/has_many ring and
queries every model, `assoc_one` has the ring but queries ONE model, `assoc_none` queries none, `none` declares plain models and queries none. Every
measurement uses an empty CRYSTAL_CACHE_DIR and prints the peak RSS in MB.
"""
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLOT = os.environ.get("CRYSTAL_SLOT", "crystal-slot")
CRYSTAL = os.environ.get("CRYSTAL_BIN", "crystal-alpha")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from performance_budget_platform import BudgetSelectionError, platform_key, select_budget

COLUMNS = """  column id : Int64, primary: true
  column first_name : String
  column email : String
  column age : Int32
  column is_active : Bool
  column score : Float64
  timestamps
"""


def command_prefix():
    environment = [
        "BENCH_ADAPTER=sqlite",
        "CURRENT_ADAPTER=sqlite",
        "CRYSTAL_WORKERS=" + os.environ.get("CRYSTAL_WORKERS", "1"),
    ]
    environment.extend(["CRYSTAL_SLOT=" + SLOT, "CRYSTAL_BIN=" + CRYSTAL])
    return " ".join(environment + ["python3", "scripts/compile_memory.py"])


def generate(workload, count):
    src = 'require "../src/grant"\nrequire "../src/adapter/sqlite"\n'
    src += 'Grant::Connections << Grant::Adapter::Sqlite.new(name: "bench", url: "sqlite3::memory:")\n'
    for i in range(count):
        assoc = ""
        if workload in ("assoc", "assoc_one", "assoc_none"):
            assoc = "  belongs_to parent : BenchPerson%d, optional: true\n  has_many children : BenchPerson%d, foreign_key: parent_id\n" % ((i + 1) % count, (i - 1) % count)
        src += "class BenchPerson%d < Grant::Base\n  connection bench\n  table people_%d\n%s%send\n" % (i, i, COLUMNS, assoc)
    src += 'checksum = 0.0\nif ARGV.includes?("--run")\n'
    queried = {"assoc_one": 1, "assoc_none": 0, "none": 0}.get(workload, count)
    for i in range(queried):
        src += "  BenchPerson%d.where(age: 37).each { |record| checksum += record.score }\n" % i
    src += "end\n"
    return src


def measure(path, mode):
    cache = tempfile.mkdtemp(prefix="compile_memory_")
    flags = {"semantic": ["--no-codegen"], "debug": []}[mode]
    out = os.path.join(cache, "probe_bin")
    slot = [SLOT] if SLOT else []
    if platform.system() == "Darwin":
        timer = ["/usr/bin/time", "-l"]
    else:
        timer = ["/usr/bin/time", "-v"]
    link_flags = ["--link-flags=-Wl,--no-export-dynamic"] if platform.system() == "Linux" else []
    cmd = [*slot, *timer, CRYSTAL, "build", "--no-color", *flags, *link_flags, path, "-o", out]
    env = dict(os.environ, CRYSTAL_CACHE_DIR=os.path.join(cache, "cache"))
    env.setdefault("CRYSTAL_WORKERS", "1")
    try:
        done = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
        output = done.stdout + done.stderr
        if done.returncode != 0:
            print(output[-3000:])
            sys.exit(done.returncode)

        if platform.system() == "Darwin":
            rss = re.search(r"^\s*(\d+)\s+maximum resident set size", output, re.M)
            if rss:
                return int(rss[1]) / 1e6
        else:
            rss = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", output)
            if rss:
                return int(rss[1]) * 1024 / 1e6
        raise RuntimeError("could not read peak RSS from /usr/bin/time output:\n" + output[-3000:])
    finally:
        shutil.rmtree(cache, ignore_errors=True)


def probe_peak(workload, count, mode="semantic"):
    os.makedirs(os.path.join(ROOT, ".crystal-cache"), exist_ok=True)
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False, dir=os.path.join(ROOT, ".crystal-cache")) as f:
        f.write(generate(workload, count))
    try:
        return measure(f.name, mode)
    finally:
        os.unlink(f.name)


def slope(workload, low=10, high=200):
    """Semantic MB per model between *low* and *high* generated models."""
    return (probe_peak(workload, high) - probe_peak(workload, low)) / (high - low)


def check(raw_json_path=None):
    budget_path = os.path.join(ROOT, "bench", "budgets.json")
    with open(budget_path, encoding="utf-8") as budget_file:
        data = json.load(budget_file)

    key, platform_budget = select_budget(budget_path)
    compile_budget = platform_budget.get("compile")
    if not compile_budget:
        raise BudgetSelectionError("performance budget for %s has no compile limits" % key)
    conditions = compile_budget.get("conditions")
    if not isinstance(conditions, dict):
        raise BudgetSelectionError("compile budget for %s has no measurement conditions; run calibrate and add its block" % key)
    expected_workers = conditions.get("CRYSTAL_WORKERS")
    if expected_workers is None:
        raise BudgetSelectionError("compile budget for %s does not record CRYSTAL_WORKERS" % key)
    current_conditions = {
        "adapter": "sqlite",
        "cache": "empty",
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
        raise BudgetSelectionError("compile budget for %s has different measurement conditions: %s" % (key, details))
    definitions = data.get("compile_probe_suite", {})
    probes = compile_budget.get("probes", {})
    missing = sorted(set(definitions) - set(probes))
    unexpected = sorted(set(probes) - set(definitions))
    if missing or unexpected:
        raise BudgetSelectionError("compile budget for %s does not match probe suite (missing: %s; unexpected: %s)" % (key, ", ".join(missing) or "none", ", ".join(unexpected) or "none"))
    for name, probe in definitions.items():
        budget = probes[name]
        expected_headroom = 10 if probe.get("mode") == "debug" else 5
        if budget.get("headroom_percent") != expected_headroom:
            raise BudgetSelectionError("compile budget for %s probe %s must use %d%% headroom for %s mode" % (key, name, expected_headroom, probe.get("mode", "semantic")))

    failures = []
    measurements = {}
    os.environ["BENCH_ADAPTER"] = "sqlite"
    os.environ["CURRENT_ADAPTER"] = "sqlite"
    for name, probe in definitions.items():
        if probe["kind"] == "peak":
            if "path" in probe:
                value = measure(probe["path"], probe["mode"])
            else:
                value = probe_peak(probe["workload"], probe["count"], probe["mode"])
        elif probe["kind"] == "slope":
            value = slope(probe["workload"], probe["low"], probe["high"])
        else:
            raise ValueError("unknown compile probe kind for %s: %s" % (name, probe["kind"]))

        budget = probes[name]
        limit = budget["limit_mb"]
        print("%s [%s]: %.1f MB (limit %.1f; set from %.1f MB)" % (name, key, value, limit, budget["measured_mb"]), flush=True)
        measurements[name] = {
            "measured_mb": round(value, 1),
            "limit_mb": limit,
            "passed": value <= limit,
        }
        if value > limit:
            failures.append(name)

    if raw_json_path:
        result = {
            "platform_key": key,
            "conditions": conditions,
            "compile_probe_results": measurements,
            "check_command": command_prefix() + " check --json-output <result.json>",
        }
        with open(raw_json_path, "w", encoding="utf-8") as output_file:
            json.dump(result, output_file, indent=2, sort_keys=True)
            output_file.write("\n")
    if failures:
        print("over the limit: " + ", ".join(failures))
        sys.exit(1)


def measure_named_probe(probe):
    os.environ["BENCH_ADAPTER"] = "sqlite"
    os.environ["CURRENT_ADAPTER"] = "sqlite"
    if probe["kind"] == "peak":
        if "path" in probe:
            return measure(probe["path"], probe["mode"])
        return probe_peak(probe["workload"], probe["count"], probe["mode"])
    if probe["kind"] == "slope":
        return slope(probe["workload"], probe["low"], probe["high"])
    raise ValueError("unknown compile probe kind: %s" % probe["kind"])


def calibrate(runs=1):
    if runs < 1:
        raise ValueError("--runs must be positive")

    os.environ.setdefault("CRYSTAL_WORKERS", "1")

    budget_path = os.path.join(ROOT, "bench", "budgets.json")
    with open(budget_path, encoding="utf-8") as budget_file:
        data = json.load(budget_file)
    key = platform_key()
    definitions = data.get("compile_probe_suite", {})
    if not definitions:
        raise BudgetSelectionError("compile_probe_suite is empty in %s" % budget_path)

    samples = {name: [] for name in definitions}
    for run in range(runs):
        for name, probe in definitions.items():
            value = measure_named_probe(probe)
            samples[name].append(round(value, 1))
            print("run %d/%d %s: %.1f MB" % (run + 1, runs, name, value), file=sys.stderr, flush=True)

    probes = {}
    for name, values in samples.items():
        measured = max(values)
        definition = definitions[name]
        prefix = command_prefix()
        if definition["kind"] == "slope":
            command = "%s slope %s %d %d" % (prefix, definition["workload"], definition["low"], definition["high"])
        elif "path" in definition:
            command = "%s file %s %s" % (prefix, definition["path"], definition["mode"])
        else:
            command = "%s probe %s %d %s" % (prefix, definition["workload"], definition["count"], definition["mode"])
        headroom = 10 if definition.get("mode") == "debug" else 5
        probes[name] = {
            "measured_mb": measured,
            "limit_mb": round(measured * (1 + headroom / 100), 1),
            "headroom_percent": headroom,
            "samples_mb": values,
            "command": command,
        }

    result = {
        "platform_key": key,
        "compile": {
            "unit": "decimal MB of peak RSS",
            "measurement_runs": runs,
            "headroom_percent": {"semantic": 5, "debug": 10},
            "conditions": {
                "adapter": "sqlite",
                "cache": "empty",
                "CRYSTAL_WORKERS": os.environ["CRYSTAL_WORKERS"],
            },
            "probes": probes,
        },
        "check_command": command_prefix() + " check",
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    kind = sys.argv[1]
    if kind == "check":
        raw_json_path = None
        if len(sys.argv) == 4 and sys.argv[2] == "--json-output":
            raw_json_path = sys.argv[3]
        elif len(sys.argv) != 2:
            print("usage: scripts/compile_memory.py check [--json-output <path>]", file=sys.stderr)
            sys.exit(2)
        try:
            check(raw_json_path)
            sys.exit(0)
        except BudgetSelectionError as error:
            print(str(error), file=sys.stderr)
            sys.exit(2)
    if kind == "calibrate":
        runs = 1
        args = sys.argv[2:]
        if args:
            if len(args) == 2 and args[0] == "--runs":
                runs = int(args[1])
            else:
                print("usage: scripts/compile_memory.py calibrate [--runs N]", file=sys.stderr)
                sys.exit(2)
        try:
            calibrate(runs)
            sys.exit(0)
        except (BudgetSelectionError, ValueError) as error:
            print(str(error), file=sys.stderr)
            sys.exit(2)
    if kind == "slope":
        workload = sys.argv[2]
        low = int(sys.argv[3]) if len(sys.argv) > 3 else 10
        high = int(sys.argv[4]) if len(sys.argv) > 4 else 200
        print("%s semantic slope %d..%d: %.2f MB/model" % (workload, low, high, slope(workload, low, high)))
        sys.exit(0)
    if kind == "probe":
        workload, count = sys.argv[2], int(sys.argv[3])
        mode = sys.argv[4] if len(sys.argv) > 4 else "semantic"
        os.makedirs(os.path.join(ROOT, ".crystal-cache"), exist_ok=True)
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False, dir=os.path.join(ROOT, ".crystal-cache")) as f:
            f.write(generate(workload, count))
        label = "%s_%d" % (workload, count)
        path = f.name
    else:
        path, mode, label = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "semantic"), os.path.basename(sys.argv[2])
    print("%s %s peak_rss_mb=%.1f" % (label, mode, measure(path, mode)), flush=True)
