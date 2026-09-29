# Changelog

## Unreleased

- Re-audit the ActiveRecord 8 parity tracker against the code. It now tracks
  424 features (was 234); 54 rows previously marked complete had gaps and are
  now partial. The headline is 98 complete of 412 applicable (23.8%).
  `docs/parity/ROADMAP.md` orders the open rows into implementation waves.
- **Breaking:** `Model.count`, relation counts, and association `count`/`size`
  return `Int64`. Comparisons with integer literals continue to work; callers
  that annotate these results as `Int32` must update.
- Keep the deprecated `connection_config(**options)` method available as a
  forwarding alias for `configure_connection(**options)`.
