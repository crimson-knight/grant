#!/usr/bin/env bash
# Runs Grant's spec suite in small groups, one process at a time.
#
# Compiling every spec file into a single program instantiates the query
# builder for all ~700 spec models at once and peaks near 20 GB of RAM. This
# runner compiles and runs one group per process, sequentially: each directory
# of specs, split into chunks of at most SPEC_GROUP_MAX_FILES files (the
# largest directories otherwise peak above 10 GB). A group whose compiler or
# spec binary grows past SPEC_GROUP_MAX_RSS_GB is killed, split in half and
# retried; a single file over the limit is reported as a failure.
#
# Usage:
#   scripts/spec-groups.sh [--list] [--only <dir>]... [--shard <k>/<n>] [adapter ...]
#
# --only may be given more than once to run several directories.
# --shard k/n runs only the k-th of n near-equal slices of the groups (1-based),
# so n CI jobs can run the suite side by side. Each group carries a cost
# estimate (its spec files, weighted per directory by SPEC_GROUP_WEIGHTS) and
# the groups are dealt heaviest first to the lightest slice, so every slice
# gets about the same compile and run time.
#
# Adapters default to $CURRENT_ADAPTER, or sqlite. Each adapter uses the same
# environment the specs already read (PG_DATABASE_URL, SQLITE_DATABASE_URL,
# MYSQL_DATABASE_URL).
#
# Environment:
#   CRYSTAL                 compiler to run (default: crystal)
#   SPEC_GROUP_MAX_RSS_GB   per-group memory ceiling in GB (default: 10)
#   SPEC_GROUP_MAX_FILES    spec files per group (default: 12)
#   SPEC_GROUP_DIR_MAX_FILES  per-directory override, "dir=n dir=n" (default:
#                           spec/grant/associations=6: its files define the most
#                           models, and 12 of them peaked near 13 GB)
#   SPEC_GROUP_WEIGHTS      per-directory cost of one spec file for --shard,
#                           "dir=n dir=n" (default: spec/grant/associations=3);
#                           any other file costs 1, and every group adds a fixed
#                           cost of 4 for compiling Grant and the spec models
#   SPEC_GROUP_LOG_DIR      where per-group logs go (default: .crystal-cache/spec-groups)
#   SPEC_GROUP_FAILURE_LINES  lines of a failed group's log to print (default: 200)
#   SPEC_GROUP_INCREMENTAL  1 forces --incremental on, 0 forces it off; unset, it is
#                           used only when "$CRYSTAL spec --help" lists it (crystal-alpha
#                           does, stock Crystal does not)
#   SPEC_GROUP_CACHE        compiler cache layout: "adapter" (default) shares one
#                           CRYSTAL_CACHE_DIR per adapter; "per-group" gives each
#                           group its own, so a rerun of that group compiles warm
#                           (about 190 MB of disk per group)
#   SPEC_GROUP_CACHE_DIR    root of those caches (default: .crystal-cache/spec-groups-cache)
#   SPEC_GROUP_LINK_FLAGS   passed as --link-flags (default on Linux: -Wl,--no-export-dynamic,
#                           so GNU ld does not overflow the symbol version table; see below)
#
# Incremental compilation keeps only the last program it compiled, so a cache
# shared by every group mostly saves parse and macro work (measured on
# spec/grant/types: 6.0 GB / 17.7 s plain, 4.7 GB cold incremental, 3.3 GB /
# 11.9 s warm). Use "per-group" when rerunning the same groups while fixing them.
set -uo pipefail

cd "$(dirname "$0")/.."

crystal_bin="${CRYSTAL:-crystal}"
max_rss_kb=$(( ${SPEC_GROUP_MAX_RSS_GB:-10} * 1024 * 1024 ))
max_files="${SPEC_GROUP_MAX_FILES:-12}"
log_dir="${SPEC_GROUP_LOG_DIR:-.crystal-cache/spec-groups}"
cache_mode="${SPEC_GROUP_CACHE:-adapter}"
cache_root="${SPEC_GROUP_CACHE_DIR:-.crystal-cache/spec-groups-cache}"
spec_flags=()
case "${SPEC_GROUP_INCREMENTAL:-auto}" in
  0) ;;
  1) spec_flags+=(--incremental) ;;
  auto)
    if "$crystal_bin" spec --help 2>&1 | grep -q -- --incremental; then
      spec_flags+=(--incremental)
    fi
    ;;
  *) echo "SPEC_GROUP_INCREMENTAL must be 0 or 1, not $SPEC_GROUP_INCREMENTAL" >&2; exit 2 ;;
esac
# Crystal links with -rdynamic on Linux, so every symbol goes into .dynsym.
# GNU ld reads the "@" in Crystal's inherited-method symbols
# (*ArgumentError@Exception#initialize<String>:Nil) as a symbol version, and
# the larger groups define more than 32767 of them.
# Version indexes are 15 bits, so the glibc version references overflow and
# the binary will not start: "symbol lookup error: undefined symbol: environ,
# version <some Crystal method name>". Not exporting the symbols avoids it.
default_link_flags=""
[ "$(uname -s)" = Linux ] && default_link_flags="-Wl,--no-export-dynamic"
link_flags="${SPEC_GROUP_LINK_FLAGS-$default_link_flags}"
[ -n "$link_flags" ] && spec_flags+=("--link-flags=$link_flags")
case "$cache_mode" in
  adapter|per-group) ;;
  *) echo "SPEC_GROUP_CACHE must be adapter or per-group, not $cache_mode" >&2; exit 2 ;;
esac
list_only=false
only=()
adapters=()
shard=""
dir_max_files="${SPEC_GROUP_DIR_MAX_FILES-spec/grant/associations=6}"
dir_weights="${SPEC_GROUP_WEIGHTS-spec/grant/associations=3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=true ;;
    --only) shift; only+=("${1%/}") ;;
    --shard)
      shift
      shard="$1"
      if ! [[ "$shard" =~ ^[0-9]+/[0-9]+$ ]] || [ "${shard%/*}" -lt 1 ] || [ "${shard%/*}" -gt "${shard#*/}" ]; then
        echo "--shard takes k/n with 1 <= k <= n, not $shard" >&2; exit 2
      fi
      ;;
    -h|--help) sed -n '2,53p' "$0"; exit 0 ;;
    *) adapters+=("$1") ;;
  esac
  shift
done
[ ${#adapters[@]} -eq 0 ] && adapters=("${CURRENT_ADAPTER:-sqlite}")

# Groups are "dir" or "dir#n": the n-th chunk of at most max_files spec files
# in a directory (its direct *_spec.cr files only).
dirs=()
while IFS= read -r dir; do
  if compgen -G "$dir/*_spec.cr" > /dev/null; then
    dirs+=("$dir")
  fi
done < <(find spec -type d | sort)
[ ${#only[@]} -gt 0 ] && dirs=("${only[@]}")

# The value "dir=n" entry of *table* gives for *dir*, or *fallback*.
dir_setting() {
  local table="$1" dir="$2" fallback="$3" entry
  for entry in $table; do
    if [ "${entry%=*}" = "$dir" ]; then
      echo "${entry##*=}"
      return
    fi
  done
  echo "$fallback"
}

groups=()
for dir in "${dirs[@]}"; do
  count=$(ls "$dir"/*_spec.cr | wc -l | tr -d ' ')
  limit=$(dir_setting "$dir_max_files" "$dir" "$max_files")
  if [ "$count" -le "$limit" ]; then
    groups+=("$dir")
  else
    chunks=$(( (count + limit - 1) / limit ))
    for n in $(seq 1 "$chunks"); do groups+=("$dir#$n"); done
  fi
done

# The spec files of a group, one per line.
group_files() {
  local dir="${1%%#*}" n limit
  if [ "$1" = "$dir" ]; then
    ls "$dir"/*_spec.cr
  else
    n="${1##*#}"
    limit=$(dir_setting "$dir_max_files" "$dir" "$max_files")
    ls "$dir"/*_spec.cr | sed -n "$(( (n - 1) * limit + 1 )),$(( n * limit ))p"
  fi
}

# Keeps the groups of slice k of n: heaviest group first, each to the slice
# with the least estimated cost so far (ties go to the lower slice).
if [ -n "$shard" ]; then
  shard_index=$(( ${shard%/*} - 1 ))
  shard_count="${shard#*/}"
  weighted=()
  for group in "${groups[@]}"; do
    files=$(group_files "$group" | wc -l | tr -d ' ')
    weight=$(( 4 + files * $(dir_setting "$dir_weights" "${group%%#*}" 1) ))
    weighted+=("$weight $group")
  done
  loads=()
  for _ in $(seq 1 "$shard_count"); do loads+=(0); done
  kept=()
  while read -r weight group; do
    lightest=0
    for i in "${!loads[@]}"; do
      [ "${loads[$i]}" -lt "${loads[$lightest]}" ] && lightest=$i
    done
    loads[lightest]=$(( loads[lightest] + weight ))
    [ "$lightest" -eq "$shard_index" ] && kept+=("$group")
  done < <(printf '%s\n' "${weighted[@]}" | sort -k1,1nr -k2,2)
  groups=(${kept[@]+"${kept[@]}"})
fi

if $list_only; then
  for group in "${groups[@]}"; do
    printf '%3d  %s\n' "$(group_files "$group" | wc -l)" "$group"
  done
  exit 0
fi

mkdir -p "$log_dir"

# Largest resident set (KB) of a process and all of its descendants.
tree_rss_kb() {
  local pids=("$1") total=0 child pid rss
  while [ ${#pids[@]} -gt 0 ]; do
    pid="${pids[0]}"
    pids=("${pids[@]:1}")
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$rss" ] && total=$(( total + rss ))
    for child in $(pgrep -P "$pid" 2>/dev/null); do pids+=("$child"); done
  done
  echo "$total"
}

kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" 2>/dev/null
}

# Runs one group; sets $status, $summary, $peak_gb, $elapsed, $over_limit and $group_log.
run_group() {
  local adapter="$1" label="$2" files="$3" log cache runner rss_kb peak_kb=0 started=$SECONDS
  local slug
  slug="$(echo "$label" | tr '/#.' '___')"
  log="$log_dir/${adapter}_$slug.log"
  group_log="$log"
  cache="$cache_root/$adapter"
  [ "$cache_mode" = "per-group" ] && cache="$cache_root/$adapter/$slug"
  mkdir -p "$cache"
  over_limit=false

  # shellcheck disable=SC2086 # spec paths contain no spaces
  CURRENT_ADAPTER="$adapter" CRYSTAL_CACHE_DIR="$cache" \
    "$crystal_bin" spec ${spec_flags[@]+"${spec_flags[@]}"} $files > "$log" 2>&1 &
  runner=$!
  while kill -0 "$runner" 2>/dev/null; do
    rss_kb=$(tree_rss_kb "$runner")
    [ "$rss_kb" -gt "$peak_kb" ] && peak_kb=$rss_kb
    if [ "$rss_kb" -gt "$max_rss_kb" ]; then
      over_limit=true
      kill_tree "$runner"
      break
    fi
    sleep 1
  done
  wait "$runner" 2>/dev/null
  status=$?

  summary=$(grep -E '^[0-9]+ examples,' "$log" | tail -1)
  [ -z "$summary" ] && summary="no summary (see $log)"
  peak_gb=$(awk "BEGIN { printf \"%.1f\", $peak_kb / 1048576 }")
  elapsed=$(( SECONDS - started ))
}

failed=()
for adapter in "${adapters[@]}"; do
  # Queue entries are "label|file file ...".
  queue=()
  for group in "${groups[@]}"; do
    queue+=("$group|$(group_files "$group" | tr '\n' ' ')")
  done

  while [ ${#queue[@]} -gt 0 ]; do
    entry="${queue[0]}"
    queue=("${queue[@]:1}")
    label="${entry%%|*}"
    files="${entry#*|}"
    read -ra file_list <<< "$files"

    run_group "$adapter" "$label" "$files"

    if $over_limit && [ ${#file_list[@]} -gt 1 ]; then
      half=$(( ${#file_list[@]} / 2 ))
      printf '%-7s %-40s %-52s %5sGB %4ss\n' "$adapter" "$label" "over the limit: splitting in two" "$peak_gb" "$elapsed"
      queue=("$label.a|${file_list[*]:0:half}" "$label.b|${file_list[*]:half}" "${queue[@]+"${queue[@]}"}")
      continue
    fi

    if $over_limit; then
      summary="killed: over ${SPEC_GROUP_MAX_RSS_GB:-10} GB"
      status=1
    fi
    printf '%-7s %-40s %-52s %5sGB %4ss\n' "$adapter" "$label" "$summary" "$peak_gb" "$elapsed"
    if [ "$status" -ne 0 ]; then
      failed+=("$adapter $label")
      # Show why: the spec failures, or the end of the log when it never ran.
      if grep -q '^Failures:' "$group_log"; then
        sed -n '/^Failures:/,$p' "$group_log" | head -n "${SPEC_GROUP_FAILURE_LINES:-200}" | sed 's/^/    /'
      else
        tail -n 40 "$group_log" | sed 's/^/    /'
      fi
    fi
  done
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "Failed groups:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo
echo "All ${#groups[@]} groups passed on: ${adapters[*]}"
