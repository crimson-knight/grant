#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_directory="$repository_root/spec/api_card_probes"

export CRYSTAL_PATH="$repository_root/src:$repository_root/lib"
export CRYSTAL_WORKERS=1
export CRYSTAL_CACHE_DIR="$repository_root/.crystal-cache/api-card-probes"

probe_count=0
error_count=0
warning_count=0
expected_failure_count=0

while IFS= read -r probe_path; do
  probe_count=$((probe_count + 1))
  if output=$(crystal-alpha build --no-codegen --no-color -Dgrant_docs "$probe_path" 2>&1); then
    warning_lines=$(printf '%s\n' "$output" | grep -Eic 'warning:' || true)
    warning_count=$((warning_count + warning_lines))
    if (( warning_lines > 0 )); then
      printf 'Warnings in %s:\n%s\n' "${probe_path#"$repository_root"/}" "$output"
    fi
  else
    error_count=$((error_count + 1))
    printf 'Compile error in %s:\n%s\n' "${probe_path#"$repository_root"/}" "$output"
  fi
done < <(find "$probe_directory" -type f -name '*.cr' ! -name 'probe_support.cr' ! -name '*.expected_failure.cr' -print | sort)

expected_failure_probe="$probe_directory/hint_encrypts_ignore_case_untyped.expected_failure.cr"
if [[ ! -f "$expected_failure_probe" ]]; then
  printf 'Probe compile result: RED (expected-failure probe is missing)\n'
  exit 1
fi

if output=$(crystal-alpha build --no-codegen --no-color -Dgrant_docs "$expected_failure_probe" 2>&1); then
  error_count=$((error_count + 1))
  printf 'Expected compile failure in %s, but it compiled.\n' "${expected_failure_probe#"$repository_root"/}"
else
  warning_lines=$(printf '%s\n' "$output" | grep -Eic 'warning:' || true)
  warning_count=$((warning_count + warning_lines))
  if printf '%s\n' "$output" | grep -Fq 'ignore_case: true needs the typed form'; then
    expected_failure_count=1
    printf 'Expected typed-form compiler error in %s.\n' "${expected_failure_probe#"$repository_root"/}"
  else
    error_count=$((error_count + 1))
    printf 'Unexpected compile error in %s:\n%s\n' "${expected_failure_probe#"$repository_root"/}" "$output"
  fi
fi

if (( probe_count == 0 )); then
  printf 'Probe compile result: RED (0 probe files found)\n'
  exit 1
elif (( error_count > 0 )); then
  printf 'Probe compile result: RED (errors=%d, warnings=%d, probes=%d)\n' "$error_count" "$warning_count" "$probe_count"
  exit 1
elif (( warning_count > 0 )); then
  printf 'Probe compile result: YELLOW (errors=0, warnings=%d, probes=%d)\n' "$warning_count" "$probe_count"
  exit 1
elif (( expected_failure_count != 1 )); then
  printf 'Probe compile result: RED (expected_failures=%d, probes=%d)\n' "$expected_failure_count" "$probe_count"
  exit 1
else
  printf 'Probe compile result: GREEN (errors=0, warnings=0, probes=%d, expected_failures=%d)\n' "$probe_count" "$expected_failure_count"
fi
