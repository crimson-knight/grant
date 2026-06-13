# MySQL-family compatibility & authentication

Grant talks to MySQL through the `crystal-lang/crystal-mysql` driver. Modern
MySQL servers default to the **`caching_sha2_password`** authentication plugin,
which Grant now supports via that driver (upstream PR #123, bridged into Grant —
see [`testing_mysql_auth.md`](testing_mysql_auth.md) and the project root
`GRANT_FINALIZATION_PLAN.md`, Thread C).

This document is the breadth-of-support map: which MySQL-compatible servers
Grant authenticates against, how, and where the gaps are.

## The short version

- **One auth implementation (`caching_sha2_password`) covers nearly the entire
  MySQL family** — MySQL 8.0.4 through 9.x LTS, Percona Server, Amazon
  Aurora/RDS MySQL, Azure Database for MySQL, Google Cloud SQL, and the
  MySQL-wire-compatible distributed databases (TiDB, Vitess / PlanetScale).
- **MariaDB is the outlier.** It does *not* use `caching_sha2_password` as a
  secure default; out of the box a MariaDB user authenticates with
  `mysql_native_password`, which Grant also supports (the legacy SHA-1 challenge
  handshake). MariaDB's *secure* auth options are **`ed25519`** and **PARSEC**,
  which are a **separate, unbuilt feature** (see [Gaps](#known-gaps--future-work)).

## How `caching_sha2_password` works (and why SHA-1 matters)

`caching_sha2_password` has two paths:

1. **Fast auth** — when the server already has the user's password hash cached
   (any prior successful login this server uptime), the client proves knowledge
   with a SHA-256 scramble. No public-key crypto. (AuthMoreData `0x03`.)
2. **Full auth** — on a *cold cache* (first login after server start / cache
   flush). The client must send the actual password to the server, protected
   one of two ways (AuthMoreData `0x04`):
   - **Over TLS:** the password is sent as cleartext inside the TLS tunnel.
   - **Over a plaintext connection:** the client requests the server's RSA
     public key (auth packet `0x02`), then sends the password XOR-ed with the
     handshake nonce, **RSA-OAEP encrypted**.

The subtle, load-bearing detail in the plaintext full-auth path: MySQL's
reference client encrypts with `RSA_public_encrypt(..., RSA_PKCS1_OAEP_PADDING)`,
whose OAEP digest **and** MGF1 are **SHA-1**. On OpenSSL 3 the provider-backed
RSA defaults the OAEP digest to **SHA-256** — so a naive implementation produces
ciphertext the server cannot decrypt, surfacing as a misleading
`Access denied (using password: YES)`. The bridged driver explicitly sets the
OAEP digest to **SHA-1**, which is what makes cold-cache logins over plaintext
work. (Grant's own pre-bridge implementation caught exactly this bug; PR #123
already does it correctly.)

> Practical note: to exercise the RSA full-auth path, connect with
> `?ssl-mode=disabled`. With the driver default (`ssl-mode=preferred`) a TCP
> connection negotiates TLS and full-auth uses the cleartext-over-TLS path,
> never touching RSA.

## Support matrix

| Server / service | Default auth plugin | Grant support | Path |
|------------------|---------------------|---------------|------|
| MySQL 8.0.4 – 8.0.x | `caching_sha2_password` | Yes | fast + full (RSA SHA-1 / TLS) |
| MySQL 8.4 LTS | `caching_sha2_password` (native_password **disabled** by default) | Yes | fast + full |
| MySQL 9.x LTS | `caching_sha2_password` | Yes | fast + full |
| Percona Server 8.0 / 8.4 | `caching_sha2_password` | Yes | fast + full (MySQL-identical) |
| Amazon Aurora MySQL / RDS (8.0/8.4) | `caching_sha2_password` | Yes (same impl) | fast + full |
| Azure Database for MySQL (8.0+) | `caching_sha2_password` | Yes (same impl) | fast + full |
| Google Cloud SQL for MySQL (8.0+) | `caching_sha2_password` | Yes (same impl) | fast + full |
| TiDB | MySQL-wire (`caching_sha2_password` / `mysql_native_password`) | Yes (same impl) | per server config |
| Vitess / PlanetScale | MySQL-wire | Yes (same impl) | per server config |
| **MariaDB 10.x / 11.x LTS** | **`mysql_native_password`** | Yes, **via native_password only** | legacy SHA-1 challenge |
| MariaDB 12.1+ | `mysql_native_password` (caching_sha2 only as an **off-by-default shim**) | native_password yes; caching_sha2 N/A in practice | — |

"Same impl" rows are MySQL-wire-protocol services that reuse the exact MySQL
8.0+ `caching_sha2_password` handshake — there is nothing server-specific in the
client, so they are covered by the single implementation. They are listed as
*expected-compatible by protocol identity*; the directly **tested** servers are
in [Tested evidence](#tested-evidence) below.

## MariaDB: the outlier in detail

MariaDB deliberately diverged from MySQL's auth roadmap:

- Its default plugin is `mysql_native_password` (the pre-8.0 SHA-1 challenge),
  which Grant supports — so **Grant connects to a default MariaDB today**.
- MariaDB's *secure* authentication story is **`ed25519`** (and, more recently,
  **PARSEC**), not `caching_sha2_password`.
- `caching_sha2_password` exists in MariaDB only from **12.1+**, and only as an
  **off-by-default compatibility shim** — it is not how a security-conscious
  MariaDB deployment authenticates.

So for MariaDB, "Grant works" means the `mysql_native_password` path works.
Genuinely *secure* MariaDB support would require implementing `ed25519`
(Curve25519 EdDSA challenge-response), which the driver does not do.

## Known gaps / future work

- **`ed25519` / PARSEC for MariaDB — not built.** This is the separate, unbuilt
  feature real MariaDB security support would need. It is intentionally out of
  scope for the `caching_sha2_password` work; documented here as a future gap,
  not a regression. Grant against MariaDB is limited to `mysql_native_password`
  until `ed25519` is implemented in the driver.

## Tested evidence

Validated live (macOS arm64, OpenSSL 3.6.2, Crystal 1.20.0) against the bridged
driver (PR #123, `crystal-mysql` 0.17.0 @ `c061324`). Each `caching_sha2`
server had its auth cache flushed and was connected to with `ssl-mode=disabled`
so the **cold-cache RSA full-auth (SHA-1 OAEP) path** was exercised, plus a
fast-auth reconnect and an insert/update/delete round-trip:

| Server | Version | Plugin | Full-auth (cold, RSA) | Fast-auth | Round-trip |
|--------|---------|--------|------------------------|-----------|------------|
| MySQL 8.0 | 8.0.46 | caching_sha2_password | PASS | PASS | PASS |
| MySQL 8.4 LTS | 8.4.9 | caching_sha2_password | PASS | PASS | PASS |
| MySQL 9.x LTS | 9.7.0 | caching_sha2_password | PASS | PASS | PASS |
| Percona Server 8.0 | 8.0.46-37 | caching_sha2_password | PASS | PASS | PASS |
| MariaDB 11.8 LTS | 11.8.8 | mysql_native_password | n/a (native path) PASS | PASS | PASS |

The **MySQL 8.4** result is the strongest single proof: on 8.4 the
`mysql_native_password` plugin is installed-but-**DISABLED** by default, so a
cold-cache, plaintext connection that authenticates there *can only* have used
the `caching_sha2_password` RSA full-auth path.

Grant's own MySQL specs were additionally run through the bridge end-to-end:
`query_builder_spec` (11 examples) passed against both MySQL 8.0.46 and 9.7.0,
and `persistence_helpers_spec` (20 CRUD examples) passed against MySQL 8.0.46 —
all with 0 failures.

> Not covered: **MySQL 8.0.11** (the first `caching_sha2` GA). Its image is
> `linux/amd64`-only (no early-8.0 arm64 manifest); under qemu emulation on
> Apple Silicon the 8.0.11 entrypoint's ancient `gosu` panics before `mysqld`
> starts. It runs natively on amd64 CI — see the `amd64-only` compose profile in
> `docker-compose.test.yml`. The 8.0.46 row covers the 8.0 line otherwise.

See [`testing_mysql_auth.md`](testing_mysql_auth.md) for how to stand up the
version matrix and reproduce this evidence.
