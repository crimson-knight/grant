#!/usr/bin/env python3
"""Compile-memory probe for Grant: generates N models and measures peak RSS.

Usage (from the repo root, one compile at a time through crystal-slot):

  scripts/compile_memory.py probe <query|assoc|assoc_one> <count> [semantic|debug]
  scripts/compile_memory.py file <path.cr> [semantic|debug]

`query` queries every model once, `assoc` adds a belongs_to/has_many ring and
queries every model, `assoc_one` has the ring but queries ONE model. Every
measurement uses an empty CRYSTAL_CACHE_DIR and prints the peak RSS in MB.
"""
import os
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
        if workload in ("assoc", "assoc_one"):
            assoc = "  belongs_to parent : BenchPerson%d, optional: true\n  has_many children : BenchPerson%d, foreign_key: parent_id\n" % ((i + 1) % count, (i - 1) % count)
        src += "class BenchPerson%d < Grant::Base\n  connection bench\n  table people_%d\n%s%send\n" % (i, i, COLUMNS, assoc)
    src += 'checksum = 0.0\nif ARGV.includes?("--run")\n'
    queried = 1 if workload == "assoc_one" else count
    for i in range(queried):
        src += "  BenchPerson%d.where(age: 37).each { |record| checksum += record.score }\n" % i
    src += "end\n"
    return src


def measure(path, mode):
    cache = tempfile.mkdtemp(prefix="compile_memory_")
    flags = {"semantic": ["--no-codegen"], "debug": []}[mode]
    out = os.path.join(cache, "probe_bin")
    cmd = [SLOT, "/usr/bin/time", "-l", CRYSTAL, "build", "--no-color", *flags, path, "-o", out]
    env = dict(os.environ, CRYSTAL_CACHE_DIR=os.path.join(cache, "cache"))
    done = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    text = done.stdout + done.stderr
    rss = re.search(r"^\s*(\d+)\s+maximum resident set size", text, re.M)
    shutil.rmtree(cache, ignore_errors=True)
    if done.returncode != 0:
        print(text[-3000:])
        sys.exit(done.returncode)
    return int(rss[1]) / 1e6 if rss else float("nan")


if __name__ == "__main__":
    kind = sys.argv[1]
    if kind == "probe":
        workload, count = sys.argv[2], int(sys.argv[3])
        mode = sys.argv[4] if len(sys.argv) > 4 else "semantic"
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False, dir=os.path.join(ROOT, ".crystal-cache")) as f:
            f.write(generate(workload, count))
        label = "%s_%d" % (workload, count)
        path = f.name
    else:
        path, mode, label = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "semantic"), os.path.basename(sys.argv[2])
    print("%s %s peak_rss_mb=%.1f" % (label, mode, measure(path, mode)), flush=True)
