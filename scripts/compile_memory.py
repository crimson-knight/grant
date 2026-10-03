#!/usr/bin/env python3
"""Compile-memory probe for Grant: generates N models and measures peak RSS.

Usage (from the repo root, one compile at a time through crystal-slot):

  scripts/compile_memory.py probe <query|assoc|assoc_one|assoc_none|none> <count> [semantic|debug]
  scripts/compile_memory.py file <path.cr> [semantic|debug]
  scripts/compile_memory.py slope <query|assoc> [low] [high]
  scripts/compile_memory.py check

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

COLUMNS = """  column id : Int64, primary: true
  column first_name : String
  column email : String
  column age : Int32
  column is_active : Bool
  column score : Float64
  timestamps
"""


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


def check():
    budget_path = os.path.join(ROOT, "bench", "budgets.json")
    with open(budget_path, encoding="utf-8") as budget_file:
        probes = json.load(budget_file)["compile"]["probes"]

    failures = []
    os.environ["BENCH_ADAPTER"] = "sqlite"
    os.environ["CURRENT_ADAPTER"] = "sqlite"
    for name, probe in probes.items():
        if probe["kind"] == "peak":
            if "path" in probe:
                value = measure(probe["path"], probe["mode"])
            else:
                value = probe_peak(probe["workload"], probe["count"], probe["mode"])
        elif probe["kind"] == "slope":
            value = slope(probe["workload"], probe["low"], probe["high"])
        else:
            raise ValueError("unknown compile probe kind for %s: %s" % (name, probe["kind"]))

        limit = probe["limit_mb"]
        print("%s: %.1f MB (limit %.1f; set from %.1f MB)" % (name, value, limit, probe["measured_mb"]), flush=True)
        if value > limit:
            failures.append(name)
    if failures:
        print("over the limit: " + ", ".join(failures))
        sys.exit(1)


if __name__ == "__main__":
    kind = sys.argv[1]
    if kind == "check":
        check()
        sys.exit(0)
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
