# Changelog

## Unreleased

- **Breaking:** `Model.count`, relation counts, and association `count`/`size`
  return `Int64`. Comparisons with integer literals continue to work; callers
  that annotate these results as `Int32` must update.
- Keep the deprecated `connection_config(**options)` method available as a
  forwarding alias for `configure_connection(**options)`.
