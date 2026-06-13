# Testing Grant against MySQL 8 / 9 (`caching_sha2_password`)

This document covers the **dedicated MySQL test infrastructure** for exercising
Grant's authentication against default-configured MySQL 8.x and 9.x, whose
default auth plugin is `caching_sha2_password`.

> This is Thread 3b of the multi-target / scale plan
> (`GRANT_MULTI_TARGET_AND_SCALE_PLAN.md` §3.3). It provides **only the test
> images, bring-up tooling, CI, and docs** — the actual `caching_sha2_password`
> handshake / OpenSSL3 binding work lives in the MySQL adapter / `crystal-mysql`
> fork (Thread 3 / 3a).

## Why a dedicated image?

The existing `mysql-primary` / `mysql-replica` services in
`docker-compose.test.yml` are general-purpose. The `mysql8` and `mysql9`
services added here are specifically configured to run with the **default
`caching_sha2_password` plugin** and **no `mysql_native_password` override**, so
they reproduce exactly what a user hits when pointing Grant at an out-of-the-box
MySQL 8 or 9 server.

## Services, ports, and credentials

Defined in `docker-compose.test.yml`:

| Service  | Image        | Host port | Container port | Auth plugin (default) |
|----------|--------------|-----------|----------------|-----------------------|
| `mysql8` | `mysql:8.0`  | **3308**  | 3306           | `caching_sha2_password` |
| `mysql9` | `mysql:9.0`  | **3309**  | 3306           | `caching_sha2_password` |

Ports 3308/3309 were chosen to avoid clashing with the pre-existing
`mysql-primary` (3306) and `mysql-replica` (3307) services, so all four can run
at once.

### Version matrix (Thread C)

On top of `mysql8`/`mysql9`, the compose file defines a **version matrix** so
the `caching_sha2_password` handshake can be validated across the breadth of the
MySQL family, plus the MariaDB outlier and Percona. See
[`mysql_compatibility.md`](mysql_compatibility.md) for what each row proves.

| Service     | Image                        | Host port | Default plugin            | Notes |
|-------------|------------------------------|-----------|---------------------------|-------|
| `mysql8011` | `mysql:8.0.11`               | **3310**  | `caching_sha2_password`   | First GA. **amd64-only** image — `amd64-only` compose profile; crashes under qemu on Apple Silicon, run on amd64 CI. |
| `mysql8046` | `mysql:8.0`                  | **3311**  | `caching_sha2_password`   | Current 8.0.x point release. |
| `mysql84`   | `mysql:8.4`                  | **3312**  | `caching_sha2_password`   | 8.4 LTS — `mysql_native_password` is **disabled** by default (strictest). |
| `mysql97`   | `mysql:9.7`                  | **3313**  | `caching_sha2_password`   | 9.x LTS — `--default-authentication-plugin` removed. |
| `mariadb`   | `mariadb:11.8`               | **3314**  | `mysql_native_password`   | **The outlier.** caching_sha2 is N/A; uses its own init dir (`docker/mariadb-auth-init`). |
| `percona80` | `percona/percona-server:8.0` | **3315**  | `caching_sha2_password`   | MySQL-identical full-auth path. |

`mysql8011` is in the `amd64-only` profile, so a plain `up` skips it on arm64.
On an amd64 host/CI run it with:

```sh
docker compose -f docker-compose.test.yml --profile amd64-only up -d mysql8011
# or: make mysql-auth-8011-amd64
```

Credentials (MySQL/Percona created by
`docker/mysql-auth-init/01-caching-sha2-user.sql`; MariaDB by
`docker/mariadb-auth-init/01-native-user.sql`):

| Field    | Value           |
|----------|-----------------|
| Database | `grant_test`    |
| User     | `grant`         |
| Password | `test_password` |
| Root pw  | `root_password` |

A second user `grant_nopass` (empty password, `caching_sha2_password`) exists to
exercise the empty-password branch of the handshake. It is optional.

The test user is **explicitly** created with
`IDENTIFIED WITH caching_sha2_password` so the intent is unambiguous and robust
across MySQL point releases.

## One-command bring-up

```sh
make mysql-auth-test          # up + wait-healthy + verify auth, prints conn info
# or directly:
./scripts/mysql-auth-test.sh up
```

The script (`scripts/mysql-auth-test.sh`) brings up `mysql8` and `mysql9`,
**polls `docker inspect` health** (which runs `mysqladmin ping` inside each
container) until both are healthy or a timeout (`MYSQL_AUTH_MAX_WAIT`, default
180s) elapses, then connects as the `grant` user to prove
`caching_sha2_password` authentication succeeds. This wait loop is what keeps a
spec run from racing server startup.

Other subcommands / Make targets:

| Command                  | Make target          | Purpose                                   |
|--------------------------|----------------------|-------------------------------------------|
| `... up`                 | `make mysql-auth-test` | bring up, wait, verify                   |
| `... down`               | `make mysql-auth-down` | tear down + remove volumes               |
| `... ping`               | `make mysql-auth-ping` | re-verify auth against running images    |
| `... pubkey`             | `make mysql-auth-pubkey` | dump each server's RSA public key      |
| `docker compose ... config` | `make mysql-auth-config` | validate the compose file            |

Tear down when done:

```sh
make mysql-auth-down          # docker compose rm -fsv mysql8 mysql9
```

## Pointing specs at it

Set `CURRENT_ADAPTER=mysql` and a `MYSQL_DATABASE_URL` pointing at the chosen
port:

```sh
# MySQL 8:
CURRENT_ADAPTER=mysql \
MYSQL_DATABASE_URL=mysql://grant:test_password@127.0.0.1:3308/grant_test \
crystal spec

# MySQL 9:
CURRENT_ADAPTER=mysql \
MYSQL_DATABASE_URL=mysql://grant:test_password@127.0.0.1:3309/grant_test \
crystal spec
```

Connection URLs (append `?ssl-mode=disabled` to force the RSA full-auth path):

- `mysql8`:    `mysql://grant:test_password@127.0.0.1:3308/grant_test?ssl-mode=disabled`
- `mysql9`:    `mysql://grant:test_password@127.0.0.1:3309/grant_test?ssl-mode=disabled`
- `mysql8046`: `mysql://grant:test_password@127.0.0.1:3311/grant_test?ssl-mode=disabled`
- `mysql84`:   `mysql://grant:test_password@127.0.0.1:3312/grant_test?ssl-mode=disabled`
- `mysql97`:   `mysql://grant:test_password@127.0.0.1:3313/grant_test?ssl-mode=disabled`
- `mariadb`:   `mysql://grant:test_password@127.0.0.1:3314/grant_test` (native_password)
- `percona80`: `mysql://grant:test_password@127.0.0.1:3315/grant_test?ssl-mode=disabled`

> **`caching_sha2_password` is now implemented** via the bridged
> `crystal-mysql` PR #123 (see `shard.yml` and
> [`mysql_compatibility.md`](mysql_compatibility.md)). Connect with
> `?ssl-mode=disabled` to exercise the **RSA full-auth (SHA-1 OAEP)** path; with
> the driver default (`ssl-mode=preferred`) a TCP connection negotiates TLS and
> full-auth uses the cleartext-over-TLS path instead, skipping RSA. Until #123
> ships a release, Grant pins `mysql` to the `pr-123` branch.

## RSA public key (full-auth path) and TLS

MySQL auto-generates a server RSA keypair (and a self-signed TLS cert) on first
boot. For the `caching_sha2_password` **full-auth** path over a *plaintext*
connection, the client requests the server's RSA public key (auth packet
`0x02`), then sends the password XOR-nonce, RSA-OAEP encrypted. The public key:

- lives in the container at `/var/lib/mysql/public_key.pem`;
- is also served to the client over the wire on request (no need to pre-fetch it
  for normal operation — Grant's auth code fetches it during the handshake).

To inspect it from the host:

```sh
make mysql-auth-pubkey
# or:
docker compose -f docker-compose.test.yml exec mysql8 cat /var/lib/mysql/public_key.pem
```

**TLS is not required.** Two valid paths exist:

1. **Plaintext + RSA** (the path Grant's OpenSSL3 code implements): public-key
   exchange then RSA-OAEP-encrypted password. This is what these images
   exercise by default.
2. **TLS**: if the client negotiates TLS, the password is sent inside the
   encrypted tunnel and no RSA step is needed. MySQL's auto-generated cert is
   available for this, but the test images do not force TLS.

## CI

`.github/workflows/spec.yml` has a dedicated `mysql-caching-sha2-spec` job that
matrixes over MySQL `8.0` and `9.0` with the default plugin (no
`mysql_native_password`), explicitly pins the `grant` user to
`caching_sha2_password`, logs the plugin assignment + server version, verifies
auth with `mysqladmin ping`, then runs `crystal spec` with
`CURRENT_ADAPTER=mysql`.

## Notes / caveats

- MySQL 9.x **removed** the `--default-authentication-plugin` server option, so
  the `mysql9` service passes no command override. The `mysql8` service passes
  `--default-authentication-plugin=caching_sha2_password` explicitly to be
  robust against older 8.0 point releases that defaulted to
  `mysql_native_password`.
- First boot of each image runs the init SQL and key/cert generation, so the
  health check uses a 30s `start_period` and up to 20 retries. The bring-up
  script's wait loop waits up to 180s.
- The init SQL is mounted read-only into `/docker-entrypoint-initdb.d` and only
  runs on a fresh data volume. `make mysql-auth-down` removes the volumes so the
  next `up` re-runs it cleanly.
