# Grant ORM — developer convenience targets.
#
# The mysql-auth-* targets stand up dedicated MySQL 8.x / 9.x images that use
# the DEFAULT caching_sha2_password auth plugin (no mysql_native_password
# override) for exercising Grant's caching_sha2_password handshake.

COMPOSE_FILE := docker-compose.test.yml
AUTH_SCRIPT  := ./scripts/mysql-auth-test.sh

.PHONY: help mysql-auth-test mysql-auth-up mysql-auth-down mysql-auth-ping \
        mysql-auth-pubkey mysql-auth-config

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

## ---------------------------------------------------------------------------
## MySQL 8/9 caching_sha2_password test infrastructure (Thread 3b)
## ---------------------------------------------------------------------------

mysql-auth-test: ## Bring up MySQL 8 + 9 (caching_sha2), wait healthy, verify auth
	$(AUTH_SCRIPT) up

mysql-auth-up: mysql-auth-test ## Alias for mysql-auth-test

mysql-auth-down: ## Tear down the MySQL 8/9 caching_sha2 images (removes volumes)
	$(AUTH_SCRIPT) down

mysql-auth-ping: ## Re-verify auth/ping against the running MySQL 8/9 images
	$(AUTH_SCRIPT) ping

mysql-auth-pubkey: ## Dump each server's RSA public key (full-auth path)
	$(AUTH_SCRIPT) pubkey

mysql-auth-config: ## Validate the docker compose test config
	docker compose -f $(COMPOSE_FILE) config >/dev/null && echo "compose config OK"
