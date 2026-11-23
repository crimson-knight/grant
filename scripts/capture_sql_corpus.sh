#!/usr/bin/env bash
# Reruns Grant's SQLite spec suite with statement capture on and writes the
# distinct statements it prepared, one per line in first-seen order, to the
# path given.
#
# Usage:
#   scripts/capture_sql_corpus.sh <output path> [spec-groups.sh options]
#
# Every option after the output path goes to scripts/spec-groups.sh (for
# example --only spec/grant/query or --shard 2/6); the adapter is always
# sqlite. The spec helper hands GRANT_SQL_CAPTURE to
# Grant.settings.sqlite_statement_capture, which writes each prepared
# statement as one line with its newlines turned into spaces, the format of
# spec/grant/sqlite_engine/corpus/grant_sql_corpus.txt. That committed corpus
# is never replaced: G3's gates are pinned to its sha256, so the output must
# be another path, and a new corpus is reviewed and committed on its own.
#
# The corpus is written even when a spec group fails, and the script then
# exits with spec-groups.sh's status.
set -uo pipefail

if [ $# -lt 1 ] || [ "${1#-}" != "$1" ]; then
  sed -n '2,19p' "$0" >&2
  exit 2
fi

output_path="$1"
shift

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
committed_corpus="$repository_root/spec/grant/sqlite_engine/corpus/grant_sql_corpus.txt"
output_directory="$(cd "$(dirname "$output_path")" 2>/dev/null && pwd)" || {
  echo "capture_sql_corpus: the directory of $output_path does not exist" >&2
  exit 2
}
output_path="$output_directory/$(basename "$output_path")"
if [ "$output_path" = "$committed_corpus" ]; then
  echo "capture_sql_corpus: refusing to replace the committed corpus; give another path" >&2
  exit 2
fi

raw_capture="$(mktemp "${TMPDIR:-/tmp}/grant_sql_capture.XXXXXX")"
trap 'rm -f "$raw_capture"' EXIT

export CURRENT_ADAPTER=sqlite
export SQLITE_DATABASE_URL="${SQLITE_DATABASE_URL:-sqlite3:./grant.db}"
export GRANT_SQL_CAPTURE="$raw_capture"

"$repository_root/scripts/spec-groups.sh" "$@" sqlite
spec_status=$?

awk '!seen[$0]++' "$raw_capture" > "$output_path"
echo "capture_sql_corpus: $(wc -l < "$raw_capture" | tr -d ' ') statements captured, $(wc -l < "$output_path" | tr -d ' ') distinct, written to $output_path"
exit "$spec_status"
