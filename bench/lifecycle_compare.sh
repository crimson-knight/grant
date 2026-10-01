#!/usr/bin/env bash
# Builds and runs bench/lifecycle_bench.cr against the working tree and against
# older Grant revisions, then writes one comparison report.
#
# For each build it records cold compile time and peak compiler memory (both a
# debug build and a --release build, each with an empty cache) and the release
# binary size, then runs the release binary. The working tree runs all three
# variants (raw, serializable, grant); older revisions run the grant variant
# only. Older revisions are checked out as detached worktrees and reuse this
# checkout's lib/ so every build links the same driver versions: only Grant
# differs.
#
# Usage:
#   bench/lifecycle_compare.sh [--adapter sqlite|pg|mysql] [--iterations N]
#                              [--rounds N] [--out DIR] [ref ...]
#
# Refs default to origin/main (Grant before the ActiveRecord parity work). A
# Granite release tag such as v0.23.4 also works: it is aliased as Grant.
#
# Environment:
#   CRYSTAL           compiler (default: crystal)
#   COMPILE_WRAPPER   command to run each build under, e.g. a compile-slot limiter
#   BENCH_DATABASE_URL  database URL for the chosen adapter
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
crystal_bin="${CRYSTAL:-crystal}"
wrapper="${COMPILE_WRAPPER:-}"
adapter=sqlite
iterations=2000
rounds=5
out_dir="$root/.crystal-cache/lifecycle"
refs=()

while [ $# -gt 0 ]; do
  case "$1" in
    --adapter) shift; adapter="$1" ;;
    --iterations) shift; iterations="$1" ;;
    --rounds) shift; rounds="$1" ;;
    --out) shift; out_dir="$1" ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) refs+=("$1") ;;
  esac
  shift
done
[ ${#refs[@]} -eq 0 ] && refs=(origin/main)
mkdir -p "$out_dir"
compile_json="$out_dir/compile_${adapter}.jsonl"
: > "$compile_json"

# Builds bench/lifecycle_bench.cr in $1 with an empty cache; appends a compile
# record to $compile_json and leaves the release binary at $3.
build_target() {
  local checkout="$1" label="$2" binary="$3" mode flags log seconds peak_bytes cache
  for mode in debug release; do
    flags=()
    [ "$mode" = release ] && flags=(--release)
    cache=$(mktemp -d)
    log="$out_dir/compile_${adapter}_${label//\//_}_$mode.log"
    # shellcheck disable=SC2086 # the wrapper is a command prefix
    (cd "$checkout" && BENCH_ADAPTER="$adapter" CRYSTAL_CACHE_DIR="$cache" \
      $wrapper /usr/bin/time -l "$crystal_bin" build ${flags[@]+"${flags[@]}"} bench/lifecycle_bench.cr -o "$binary.$mode") \
      > "$log" 2>&1 || { echo "build failed for $label ($mode); see $log" >&2; rm -rf "$cache"; return 1; }
    rm -rf "$cache"
    seconds=$(awk '/ real /{print $1}' "$log" | tail -1)
    peak_bytes=$(awk '/maximum resident set size/{print $1}' "$log" | tail -1)
    printf '{"label":"%s","mode":"%s","seconds":%s,"peak_bytes":%s,"binary_bytes":%s}\n' \
      "$label" "$mode" "$seconds" "$peak_bytes" "$(stat -f%z "$binary.$mode" 2>/dev/null || stat -c%s "$binary.$mode")" \
      >> "$compile_json"
  done
  mv "$binary.release" "$binary"
  rm -f "$binary.debug"
}

run_json=()

echo "== working tree" >&2
build_target "$root" current "$out_dir/lifecycle_current"
"$out_dir/lifecycle_current" --iterations "$iterations" --rounds "$rounds" --label current \
  --json "$out_dir/run_${adapter}_current.json" > /dev/null
run_json+=("$out_dir/run_${adapter}_current.json")

for ref in "${refs[@]}"; do
  label="${ref//\//_}"
  checkout=$(mktemp -d)/grant-$label
  echo "== $ref" >&2
  git worktree add --detach "$checkout" "$ref" > /dev/null
  # Link this checkout's shards in; some revisions already track a lib/ entry.
  if [ -d "$checkout/lib" ]; then
    for shard in "$root"/lib/*; do
      [ -e "$checkout/lib/$(basename "$shard")" ] || ln -s "$shard" "$checkout/lib/"
    done
  else
    ln -s "$root/lib" "$checkout/lib"
  fi
  mkdir -p "$checkout/bench"
  cp bench/lifecycle_bench.cr "$checkout/bench/"
  # Releases before the rename are Granite; alias it so the same file builds.
  if [ ! -f "$checkout/src/grant.cr" ] && [ -f "$checkout/src/granite.cr" ]; then
    printf 'require "./granite"\nalias Grant = Granite\n' > "$checkout/src/grant.cr"
  fi
  if build_target "$checkout" "$label" "$out_dir/lifecycle_$label"; then
    "$out_dir/lifecycle_$label" --iterations "$iterations" --rounds "$rounds" --label "$label" --grant-only \
      --json "$out_dir/run_${adapter}_$label.json" > /dev/null
    run_json+=("$out_dir/run_${adapter}_$label.json")
  fi
  git worktree remove --force "$checkout"
done

report="$out_dir/report_${adapter}.md"
# shellcheck disable=SC2086
$wrapper "$crystal_bin" run bench/lifecycle_report.cr -- "$compile_json" "${run_json[@]}" > "$report"
cat "$report"
echo >&2
echo "Report: $report" >&2
