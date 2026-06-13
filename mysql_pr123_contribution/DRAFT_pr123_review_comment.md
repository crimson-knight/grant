<!--
  DRAFT — DO NOT POST. Prepared for Seth's review/approval before anything goes
  to crystal-lang/crystal-mysql PR #123. Outward-facing.
-->

# Draft review comment for crystal-lang/crystal-mysql PR #123

**Verdict: LGTM on the full-auth crypto. The OAEP digest is correct (SHA-1), and
the caching_sha2_password full-auth-over-plaintext path round-trips against the
full breadth of live MySQL-family servers.** Sharing independent live
version-matrix evidence below, plus two small, optional robustness notes.

## What we independently validated

We compiled this PR branch (`pr-123`, head `c061324`) and ran a live probe that,
for each server, **flushes the server's caching_sha2 auth cache as root** (so the
next connection is a guaranteed cold cache → full-auth), then connects as a
`caching_sha2_password` user **with `ssl-mode=disabled`** (forcing the RSA path,
not the TLS-cleartext shortcut), runs an insert/update/delete round-trip, and
finally reconnects to exercise fast-auth (now cached).

Host: macOS arm64, OpenSSL 3.6.2, Crystal 1.20.0.

| Server | Version | User plugin | Full-auth (cold, plaintext RSA) | Fast-auth | Data round-trip |
|--------|---------|-------------|----------------------------------|-----------|-----------------|
| MySQL 8.0 | 8.0.46 | caching_sha2_password | PASS | PASS | PASS |
| MySQL 8.4 LTS | 8.4.9 | caching_sha2_password | PASS | PASS | PASS |
| MySQL 9.x LTS | 9.7.0 | caching_sha2_password | PASS | PASS | PASS |
| Percona Server 8.0 | 8.0.46-37 | caching_sha2_password | PASS | PASS | PASS |
| MariaDB 11.8 LTS | 11.8.8 | mysql_native_password | n/a (native path) PASS | PASS | PASS |

The **MySQL 8.4** row is the strongest single data point: on 8.4 the
`mysql_native_password` plugin is **installed-but-DISABLED** by default
(`information_schema.PLUGINS` shows it `DISABLED`, `caching_sha2_password`
`ACTIVE`). A cold-cache, `ssl-mode=disabled` connection that authenticates there
can *only* have completed via the `caching_sha2_password` RSA-OAEP full-auth
path. We additionally confirmed via the server `general_log` that the cold
connection produced a `Connect` event for the test user over a plaintext socket.

> One server we could not cover: **MySQL 8.0.11** (the first caching_sha2 GA).
> Its image is `linux/amd64`-only (no early-8.0 arm64 manifest), and under qemu
> emulation on Apple Silicon the 8.0.11 entrypoint's ancient `gosu` panics
> (`newosproc: failed to create new OS thread, errno=22`) before `mysqld`
> starts. This is a qemu/old-Go limitation, not a driver issue. It runs natively
> on amd64 CI; the 8.0.46 row covers the 8.0 caching_sha2 behavior otherwise.

## On the OAEP digest specifically (the subtle part)

We want to confirm the choice on `src/mysql/auth.cr`:

```crystal
# Set OAEP digest to SHA-1 (MySQL expects SHA-1, OpenSSL 3.x may default to SHA-256)
if LibCrypto.evp_pkey_ctx_set_rsa_oaep_md(ctx, LibCrypto.evp_sha1) <= 0
```

This is correct and load-bearing. MySQL's reference client encrypts the
password with `RSA_public_encrypt(..., RSA_PKCS1_OAEP_PADDING)`, whose OAEP
digest **and MGF1** are **SHA-1**. On OpenSSL 3 the provider-backed RSA defaults
the OAEP md to **SHA-256**, so omitting this line produces a ciphertext the
server cannot recover — it surfaces as a generic `Access denied (using password:
YES)`, which is easy to misdiagnose as a wrong password. We hit exactly this in
our own earlier (pre-#123) implementation; **#123 already has it right.** Worth
keeping the comment as-is so nobody "simplifies" it away.

## Two small, optional notes (non-blocking)

1. **`auth_spec.cr` has no test for `rsa_encrypt_password`.** Understandable — a
   pure-unit RSA test would only be self-consistent (encrypt+decrypt with the
   same md passes regardless of which md you pick), so it cannot catch a wrong
   OAEP digest. The real contract is only testable against a live server, which
   is what the matrix above provides. If useful, we're happy to contribute the
   live probe / a docker-compose matrix as an optional, gated integration check.

2. **OAEP padding is set via the legacy `EVP_PKEY_CTX_ctrl`** (`cmd
   EVP_PKEY_CTRL_RSA_PADDING`). It works on OpenSSL 3.6.2 in our testing. As a
   pure robustness option, the dedicated `EVP_PKEY_CTX_set_rsa_padding` function
   avoids the provider's occasional rejection of the legacy ctrl for RSA params
   on some OpenSSL 3 builds. Not needed for correctness here; just a note.

Thanks for this — it's clean and it works across the whole MySQL family.
