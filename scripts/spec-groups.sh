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
#   scripts/spec-groups.sh [--list] [--only <dir>]... [adapter ...]
#
# --only may be given more than once to run several directories.
#
# Adapters default to $CURRENT_ADAPTER, or sqlite. Each adapter uses the same
# environment the specs already read (PG_DATABASE_URL, SQLITE_DATABASE_URL,
# MYSQL_DATABASE_URL).
#
# Environment:
#   CRYSTAL                 compiler to run (default: crystal)
#   SPEC_GROUP_MAX_RSS_GB   per-group memory ceiling in GB (default: 10)
#   SPEC_GROUP_MAX_FILES    spec files per group (default: 12)
#   SPEC_GROUP_LOG_DIR      where per-group logs go (default: .crystal-cache/spec-groups)
#   SPEC_GROUP_INCREMENTAL  1 forces --incremental on, 0 forces it off; unset, it is
#                           used only when "$CRYSTAL spec --help" lists it (crystal-alpha
#                           does, stock Crystal does not)
#   SPEC_GROUP_CACHE        compiler cache layout: "adapter" (default) shares one
#                           CRYSTAL_CACHE_DIR per adapter; "per-group" gives each
#                           group its own, so a rerun of that group compiles warm
#                           (about 190 MB of disk per group)
#   SPEC_GROUP_CACHE_DIR    root of those caches (default: .crystal-cache/spec-groups-cache)
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
case "$cache_mode" in
  adapter|per-group) ;;
  *) echo "SPEC_GROUP_CACHE must be adapter or per-group, not $cache_mode" >&2; exit 2 ;;
esac
list_only=false
only=()
adapters=()

while [ $# -gt 0 ]; do
  case "$1" in
    --list) list_only=true ;;
    --only) shift; only+=("${1%/}") ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
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

groups=()
for dir in "${dirs[@]}"; do
  count=$(ls "$dir"/*_spec.cr | wc -l | tr -d ' ')
  if [ "$count" -le "$max_files" ]; then
    groups+=("$dir")
  else
    chunks=$(( (count + max_files - 1) / max_files ))
    for n in $(seq 1 "$chunks"); do groups+=("$dir#$n"); done
  fi
done

# The spec files of a group, one per line.
group_files() {
  local dir="${1%%#*}" n
  if [ "$1" = "$dir" ]; then
    ls "$dir"/*_spec.cr
  else
    n="${1##*#}"
    ls "$dir"/*_spec.cr | sed -n "$(( (n - 1) * max_files + 1 )),$(( n * max_files ))p"
  fi
}

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

# Runs one group; sets $status, $summary, $peak_gb, $elapsed and $over_limit.
run_group() {
  local adapter="$1" label="$2" files="$3" log cache runner rss_kb peak_kb=0 started=$SECONDS
  local slug
  slug="$(echo "$label" | tr '/#.' '___')"
  log="$log_dir/${adapter}_$slug.log"
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
    [ "$status" -ne 0 ] && failed+=("$adapter $label")
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
