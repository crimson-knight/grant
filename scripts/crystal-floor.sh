#!/usr/bin/env bash
# Reads and checks Grant's minimum Crystal version (the "floor").
#
# shard.yml's `crystal:` constraint is the one source of truth, for example
# `crystal: ">= 1.19.0, < 2.0.0"`. CI and the release workflow read the floor
# through this script, so no workflow repeats the version number.
#
# Usage:
#   scripts/crystal-floor.sh floor
#       Print the floor (the `>=` bound of shard.yml's `crystal:` constraint).
#   scripts/crystal-floor.sh below
#       Print the latest patch release of the minor version below the floor
#       (1.18.2 for a 1.19.0 floor), read from crystal-lang/crystal's tags.
#   scripts/crystal-floor.sh check-deps
#       Fail if a runtime dependency (shard.yml `dependencies:`, not
#       `development_dependencies:`) declares a higher Crystal floor than
#       Grant. Reads lib/<name>/shard.yml, so run `shards install` first.
#   scripts/crystal-floor.sh release-check <tag>
#       Fail unless <tag> is "v" + shard.yml `version`, and CHANGELOG.md has a
#       section for that version with a line `Minimum Crystal: <floor>`.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
  # GitHub Actions shows ::error:: lines as annotations; elsewhere they read fine.
  echo "::error::$*" >&2
  exit 1
}

# Prints the value of a top-level key in a shard.yml, without quotes.
shard_value() {
  local file="$1" key="$2"
  sed -n -E "s/^${key}:[[:space:]]*['\"]?([^'\"]*)['\"]?[[:space:]]*$/\1/p" "$file" | head -n 1
}

# Prints the lower bound of a Crystal constraint: ">= 1.19.0, < 2.0.0" gives
# 1.19.0, "~> 1.19" gives 1.19.0. Prints nothing when there is no lower bound.
lower_bound() {
  local constraint="$1" version
  version=$(printf '%s\n' "$constraint" | sed -n -E 's/.*(>=|~>)[[:space:]]*([0-9]+(\.[0-9]+){0,2}).*/\2/p')
  [ -n "$version" ] || return 0
  case "$version" in
    *.*.*) echo "$version" ;;
    *.*) echo "$version.0" ;;
    *) echo "$version.0.0" ;;
  esac
}

# Exits 0 when version $1 is greater than version $2 (both X.Y.Z).
version_greater() {
  local IFS=.
  local -a left=($1) right=($2)
  local i
  for i in 0 1 2; do
    if (( ${left[i]:-0} > ${right[i]:-0} )); then return 0; fi
    if (( ${left[i]:-0} < ${right[i]:-0} )); then return 1; fi
  done
  return 1
}

floor() {
  local constraint version
  constraint=$(shard_value shard.yml crystal)
  [ -n "$constraint" ] || fail "shard.yml has no crystal: constraint"
  version=$(printf '%s\n' "$constraint" | sed -n -E 's/.*>=[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  [ -n "$version" ] || fail "shard.yml crystal: \"$constraint\" has no \">= X.Y.Z\" lower bound"
  echo "$version"
}

below() {
  local current major minor previous latest
  current=$(floor)
  IFS=. read -r major minor _ <<<"$current"
  (( minor > 0 )) || fail "floor $current has no earlier minor version in the same major series"
  previous="$major.$((minor - 1))"
  latest=$(git ls-remote --tags --refs https://github.com/crystal-lang/crystal "refs/tags/$previous.*" |
    sed -n -E "s#.*refs/tags/($previous\.[0-9]+)\$#\1#p" |
    sort -t . -k 3,3n | tail -n 1)
  [ -n "$latest" ] || fail "no crystal-lang/crystal release tag matches $previous.*"
  echo "$latest"
}

check_deps() {
  local grant_floor name dependency_floor failed=0
  grant_floor=$(floor)
  # Two-space-indented keys under the top-level `dependencies:` block.
  local names
  names=$(sed -n -E '/^dependencies:/,/^[^[:space:]#]/s/^  ([A-Za-z0-9_-]+):[[:space:]]*$/\1/p' shard.yml)
  [ -n "$names" ] || fail "shard.yml lists no runtime dependencies"
  for name in $names; do
    [ -f "lib/$name/shard.yml" ] || fail "lib/$name/shard.yml is missing; run shards install first"
    dependency_floor=$(lower_bound "$(shard_value "lib/$name/shard.yml" crystal)")
    if [ -z "$dependency_floor" ]; then
      echo "$name: no Crystal lower bound declared"
    elif version_greater "$dependency_floor" "$grant_floor"; then
      echo "::error::$name needs Crystal >= $dependency_floor, above Grant's floor $grant_floor; raise shard.yml crystal:" >&2
      failed=1
    else
      echo "$name: Crystal >= $dependency_floor (Grant floor $grant_floor) ok"
    fi
  done
  return "$failed"
}

release_check() {
  local tag="${1:-}" version grant_floor section declared
  [ -n "$tag" ] || fail "usage: scripts/crystal-floor.sh release-check <tag>"
  version=$(shard_value shard.yml version)
  [ -n "$version" ] || fail "shard.yml has no version:"
  [ "$tag" = "v$version" ] || fail "tag $tag does not match shard.yml version $version (expected v$version)"

  # The section runs from its "## <version>" heading to the next "## " heading.
  # Accepted headings: "## 1.2.3", "## v1.2.3", "## [1.2.3]", each optionally
  # followed by a date ("## 1.2.3 - 2026-10-02").
  section=$(awk -v version="$version" '
    /^## / {
      heading = $2
      gsub(/[\[\]]/, "", heading)
      sub(/^v/, "", heading)
      in_section = (heading == version)
      if (in_section) found = 1
      next
    }
    in_section { print }
    END { if (!found) exit 1 }
  ' CHANGELOG.md) || fail "CHANGELOG.md has no \"## $version\" section"

  declared=$(printf '%s\n' "$section" | sed -n -E 's/^Minimum Crystal:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' | head -n 1)
  [ -n "$declared" ] || fail "CHANGELOG.md section $version has no \"Minimum Crystal: X.Y.Z\" line"
  grant_floor=$(floor)
  [ "$declared" = "$grant_floor" ] ||
    fail "CHANGELOG.md section $version says Minimum Crystal: $declared, but shard.yml says $grant_floor"

  echo "tag $tag matches shard.yml version $version; CHANGELOG.md declares Minimum Crystal: $declared"
}

case "${1:-}" in
  floor) floor ;;
  below) below ;;
  check-deps) check_deps ;;
  release-check) release_check "${2:-}" ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
