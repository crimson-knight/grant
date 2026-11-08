# Provenance: crystal-sqlite3

Grant owns this SQLite driver. It started as an exact copy of upstream and then moved
under the `Grant::SQLite3` namespace so an app can load the public `sqlite3` shard
beside it.

| Field | Value |
| --- | --- |
| Upstream | https://github.com/crystal-lang/crystal-sqlite3 |
| Version | 0.23.0 |
| Commit | 271a1314a6c64e6c3d98942a39bf1b3e8326b190 |
| Lock checksum | sha256:e62db0abc50b1437630a25594e175cb3e6949c21bcf55cebefdc7d3a8425988d |
| License | MIT, kept as `LICENSE` beside this note |

Changes made in Grant, on top of the renames: a private `grant-sqlite3` scheme, and
C bindings declared under LLVM's literal-symbol form in `sqlite3/lib_sqlite3.cr`, so
they coexist with the public shard's bindings of the same C functions.
