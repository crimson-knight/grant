-- Grant ORM — MariaDB test fixture (default mysql_native_password path)
--
-- MariaDB does NOT implement MySQL's caching_sha2_password as its secure
-- default. Out of the box, a MariaDB user authenticates with
-- mysql_native_password (MariaDB's "secure" options are ed25519 / PARSEC,
-- which are a SEPARATE, unbuilt feature for Grant — see
-- docs/mysql_compatibility.md). This fixture therefore creates the test user
-- with the MariaDB default plugin so we can prove the crystal-mysql driver's
-- mysql_native_password handshake still works against a real MariaDB server.
--
-- We do NOT try to force caching_sha2_password here: on MariaDB < 12.1 the
-- plugin does not exist, and even on 12.1+ it is an off-by-default shim. The
-- whole point of including MariaDB in the matrix is to confirm the
-- native_password fallback path, not to exercise caching_sha2 (N/A here).

CREATE DATABASE IF NOT EXISTS grant_test;

-- '%' host so connections from the host (mapped port) work; mysql_native_password
-- is MariaDB's default auth plugin so we let it be the default for this user.
CREATE USER IF NOT EXISTS 'grant'@'%' IDENTIFIED BY 'test_password';
ALTER USER 'grant'@'%' IDENTIFIED BY 'test_password';

CREATE USER IF NOT EXISTS 'grant'@'localhost' IDENTIFIED BY 'test_password';
ALTER USER 'grant'@'localhost' IDENTIFIED BY 'test_password';

GRANT ALL PRIVILEGES ON grant_test.* TO 'grant'@'%';
GRANT ALL PRIVILEGES ON grant_test.* TO 'grant'@'localhost';

FLUSH PRIVILEGES;
