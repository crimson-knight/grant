#!/usr/bin/env bash
set -euo pipefail

batch_count="${1:-4}"
if ! [[ "$batch_count" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive-batch-count]" >&2
  exit 2
fi

mapfile -t specs < <(find spec -type f -name '*_spec.cr' | sort)

for ((batch = 0; batch < batch_count; batch++)); do
  batch_specs=()
  for ((index = batch; index < ${#specs[@]}; index += batch_count)); do
    batch_specs+=("${specs[$index]}")
  done

  echo "Running Grant CI spec batch $((batch + 1))/$batch_count (${#batch_specs[@]} files)"
  crystal spec --no-debug "${batch_specs[@]}"
done
