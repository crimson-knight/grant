# Provenance: crystal-pg

Grant owns this Postgres driver. It started as an exact copy of upstream and then
moved under the `Grant::PG` and `Grant::PQ` namespaces so an app can load the public
`pg` shard beside it.

| Field | Value |
| --- | --- |
| Upstream | https://github.com/will/crystal-pg |
| Version | 0.30.0 |
| Commit | 1f4aefd82440cffd6e70ccb02b7d27bfbfc6d25d |
| Lock checksum | sha256:0fcacb5e2d717882de0f809b937224338d171e2a7937c97cb5d5b0306c90eff9 |
| License | BSD-3-Clause, kept as `LICENSE` beside this note |

Changes made in Grant, on top of the renames: a private `grant-postgres` scheme,
named prepared statements (`pg/statement.cr`, `pg/connection.cr`, `pq/connection.cr`,
`pq/frame.cr`), and a `disable` sslmode default for a database on the same machine
(`pq/conninfo.cr`).
