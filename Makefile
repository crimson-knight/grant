# Grant ORM — developer convenience targets.
#
# The mysql-auth-* targets stand up the MySQL-family auth matrix (MySQL 8.0.x,
# 8.4 LTS, 9.x LTS, Percona — all DEFAULT caching_sha2_password — plus the
# MariaDB native_password outlier) for exercising Grant's auth handshake. See
# docs/testing_mysql_auth.md and docs/mysql_compatibility.md.

COMPOSE_FILE := docker-compose.test.yml
AUTH_SCRIPT  := ./scripts/mysql-auth-test.sh

.PHONY: help mysql-auth-test mysql-auth-up mysql-auth-down mysql-auth-ping \
        mysql-auth-pubkey mysql-auth-config mysql-auth-matrix \
        mysql-auth-8011-amd64

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ---------------------------------------------------------------------------
## MySQL-family auth matrix (caching_sha2_password + MariaDB native_password)
## ---------------------------------------------------------------------------

mysql-auth-test: ## Bring up the auth matrix (8.0/8.4/9.x/MariaDB/Percona), wait, verify
	$(AUTH_SCRIPT) up

mysql-auth-matrix: mysql-auth-test ## Alias for mysql-auth-test (full version matrix)

mysql-auth-up: mysql-auth-test ## Alias for mysql-auth-test

mysql-auth-down: ## Tear down the auth-matrix images (removes volumes)
	$(AUTH_SCRIPT) down

mysql-auth-ping: ## Re-verify auth/ping against the running matrix images
	$(AUTH_SCRIPT) ping

mysql-auth-pubkey: ## Dump each caching_sha2 server's RSA public key (full-auth path)
	$(AUTH_SCRIPT) pubkey

mysql-auth-config: ## Validate the docker compose test config
	docker compose -f $(COMPOSE_FILE) config >/dev/null && echo "compose config OK"

mysql-auth-8011-amd64: ## Bring up MySQL 8.0.11 (first GA) — amd64 hosts/CI only
	docker compose -f $(COMPOSE_FILE) --profile amd64-only up -d mysql8011
