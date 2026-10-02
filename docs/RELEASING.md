# Releasing Grant

## Checklist

1. Bump `version:` in `shard.yml`. `src/grant/version.cr` reads it through
   `shards version`, so there is nothing else to bump.
2. In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z` (a date may
   follow, as in `## X.Y.Z - 2026-10-02`) and start a new empty
   `## Unreleased` above it. The version section must keep its
   `Minimum Crystal: A.B.C` line, matching the `>=` bound of `crystal:` in
   `shard.yml`.
3. Merge to `main` with CI green.
4. Tag the merge commit and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

`.github/workflows/release.yml` runs on the tag. It publishes nothing; it
fails if any of these fails:

- the tag is `v` + the `shard.yml` version;
- `CHANGELOG.md` has a section for that version with a
  `Minimum Crystal:` line equal to the `shard.yml` floor;
- Grant type-checks and passes the SQLite suite on exactly the floor version
  (`.github/workflows/minimum-crystal.yml`).

Run the first two checks locally before tagging:

```sh
scripts/crystal-floor.sh release-check vX.Y.Z
```

If the release workflow fails, fix `main`, delete the tag
(`git push origin :refs/tags/vX.Y.Z`), and tag again.

## The minimum Crystal version

`shard.yml`'s `crystal:` constraint (for example `">= 1.19.0, < 2.0.0"`) is
the only place the minimum is written. `scripts/crystal-floor.sh` reads it for
CI, so workflows never repeat the number.

Every pull request runs:

- **minimum-crystal** (required): installs exactly the floor version, then
  type-checks `src/grant.cr` and runs `scripts/spec-groups.sh sqlite`.
- **below-minimum** (informational): installs the latest patch of the minor
  version below the floor and expects Grant not to compile. If Grant does
  compile, the job warns that the floor may be higher than necessary.
- **formatting** also runs `scripts/crystal-floor.sh check-deps`, which fails
  if a runtime dependency declares a higher Crystal floor than Grant.

When code starts using a newer Crystal API, minimum-crystal fails. Then:

1. Find the first Crystal release that has the API (check its release notes,
   or `src/` of the crystal-lang/crystal tag).
2. Raise the `>=` bound of `crystal:` in `shard.yml` to that version.
3. Add a line under `## Unreleased` in `CHANGELOG.md`:
   `Minimum Crystal: A.B.C` (replace an existing one), plus a "Behavior
   changes" bullet that names the API and tells users on older Crystal to
   upgrade or stay on the previous Grant release.
4. Update the version in `README.md` (Requirements), `CLAUDE.md`, and
   `docs/getting-started/installation.md`.
