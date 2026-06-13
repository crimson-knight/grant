-- Grant ORM — MySQL 8/9 caching_sha2_password test fixture
--
-- This script runs once on first container start (mounted into
-- /docker-entrypoint-initdb.d). The MYSQL_USER created by the official
-- entrypoint already uses the server default auth plugin
-- (caching_sha2_password on MySQL 8.0+/9.x), but we (re)create it here
-- EXPLICITLY with that plugin so the intent is unambiguous and so the
-- fixture is robust even if the entrypoint defaults ever change.
--
-- We deliberately DO NOT set default_authentication_plugin to
-- mysql_native_password anywhere. This image is specifically for
-- exercising Grant's caching_sha2_password handshake (fast-auth + the
-- RSA-public-key full-auth path).

-- Test database (idempotent; entrypoint also creates it from MYSQL_DATABASE).
CREATE DATABASE IF NOT EXISTS grant_test;

-- Primary test user, pinned to caching_sha2_password.
-- '%' host so connections from outside the container (host -> mapped port)
-- and from localhost both work.
CREATE USER IF NOT EXISTS 'grant'@'%'
  IDENTIFIED WITH caching_sha2_password BY 'test_password';
ALTER USER 'grant'@'%'
  IDENTIFIED WITH caching_sha2_password BY 'test_password';

CREATE USER IF NOT EXISTS 'grant'@'localhost'
  IDENTIFIED WITH caching_sha2_password BY 'test_password';
ALTER USER 'grant'@'localhost'
  IDENTIFIED WITH caching_sha2_password BY 'test_password';

GRANT ALL PRIVILEGES ON grant_test.* TO 'grant'@'%';
GRANT ALL PRIVILEGES ON grant_test.* TO 'grant'@'localhost';

-- A second user with an EMPTY password to exercise the empty-password
-- caching_sha2 branch of the handshake (optional; harmless if unused).
CREATE USER IF NOT EXISTS 'grant_nopass'@'%'
  IDENTIFIED WITH caching_sha2_password BY '';
GRANT ALL PRIVILEGES ON grant_test.* TO 'grant_nopass'@'%';

FLUSH PRIVILEGES;
