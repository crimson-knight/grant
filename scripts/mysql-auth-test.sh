#!/usr/bin/env bash
#
# scripts/mysql-auth-test.sh — bring up the dedicated MySQL 8/9
# caching_sha2_password test images, wait until they are healthy and
# authenticating, and print the connection details Grant specs need.
#
# Usage:
#   scripts/mysql-auth-test.sh up      # bring up mysql8 + mysql9, wait, verify
#   scripts/mysql-auth-test.sh down    # tear down + remove volumes
#   scripts/mysql-auth-test.sh ping    # re-run the auth/ping verification only
#   scripts/mysql-auth-test.sh pubkey  # dump each server's RSA public key
#
# Defaults to "up" when no subcommand is given. Designed so a spec run can do:
#   scripts/mysql-auth-test.sh up
#   CURRENT_ADAPTER=mysql MYSQL_DATABASE_URL=mysql://grant:test_password@127.0.0.1:3308/grant_test crystal spec
#
# Portable to bash 3.2 (macOS default) — no associative arrays.
#
set -euo pipefail

# Resolve repo root from this script's location (works from any cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.test.yml"
COMPOSE=(docker compose -f "${COMPOSE_FILE}")

# Services to manage (bash 3.2: plain array, port resolved via function).
#
# The original mysql8/mysql9 services plus the Thread C version matrix:
# 8.0.x, 8.4 LTS, 9.x LTS, MariaDB (the native_password outlier), Percona.
# mysql8011 (first GA) is intentionally EXCLUDED: it is linux/amd64-only and
# crashes under qemu on Apple Silicon — run it on amd64 CI via:
#   docker compose -f docker-compose.test.yml --profile amd64-only up mysql8011
# Override the set with, e.g.:
#   MYSQL_AUTH_SERVICES="mysql8 mysql9" scripts/mysql-auth-test.sh up
SERVICES=(${MYSQL_AUTH_SERVICES:-mysql8 mysql9 mysql8046 mysql84 mysql97 mariadb percona80})

# Host port for a given service (avoids bash-4 associative arrays).
host_port_for() {
  case "$1" in
    mysql8)    echo 3308 ;;
    mysql9)    echo 3309 ;;
    mysql8011) echo 3310 ;;
    mysql8046) echo 3311 ;;
    mysql84)   echo 3312 ;;
    mysql97)   echo 3313 ;;
    mariadb)   echo 3314 ;;
    percona80) echo 3315 ;;
    *)         echo "" ;;
  esac
}

# Auth plugin we EXPECT for a service's `grant` user — caching_sha2_password for
# the MySQL/Percona servers, mysql_native_password for the MariaDB outlier.
expected_plugin_for() {
  case "$1" in
    mariadb) echo "mysql_native_password" ;;
    *)       echo "caching_sha2_password" ;;
  esac
}

# The in-container client / admin binaries (MariaDB images ship the `mariadb*`
# names; the `mysql*` names are deprecated symlinks that may be removed).
client_bin_for() {
  case "$1" in
    mariadb) echo "mariadb" ;;
    *)       echo "mysql" ;;
  esac
}
admin_bin_for() {
  case "$1" in
    mariadb) echo "mariadb-admin" ;;
    *)       echo "mysqladmin" ;;
  esac
}

USER="grant"
PASS="test_password"
DB="grant_test"
ROOT_PASS="root_password"

# How long to wait for each container to report healthy.
MAX_WAIT_SECS="${MYSQL_AUTH_MAX_WAIT:-180}"

log()  { printf '\033[1;34m[mysql-auth]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[mysql-auth]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[mysql-auth]\033[0m %s\n' "$*" >&2; }

wait_healthy() {
  local svc="$1"
  local cid
  cid="$("${COMPOSE[@]}" ps -q "${svc}")"
  if [[ -z "${cid}" ]]; then
    err "no container id for service ${svc}"
    return 1
  fi
  log "waiting for ${svc} to become healthy (up to ${MAX_WAIT_SECS}s)..."
  local waited=0
  while true; do
    local status
    status="$(docker inspect -f '{{ .State.Health.Status }}' "${cid}" 2>/dev/null || echo "unknown")"
    case "${status}" in
      healthy)
        ok "${svc} is healthy"
        return 0
        ;;
      unhealthy)
        err "${svc} reported unhealthy"
        docker logs --tail 40 "${cid}" >&2 || true
        return 1
        ;;
    esac
    if (( waited >= MAX_WAIT_SECS )); then
      err "${svc} did not become healthy within ${MAX_WAIT_SECS}s (last status: ${status})"
      docker logs --tail 40 "${cid}" >&2 || true
      return 1
    fi
    sleep 3
    waited=$(( waited + 3 ))
  done
}

# Verify the test user authenticates with the EXPECTED plugin for this service
# (caching_sha2_password for MySQL/Percona, mysql_native_password for the
# MariaDB outlier) and that the server has that plugin assigned to the user.
# Runs the client INSIDE the container (so it doesn't depend on a host client).
verify_auth() {
  local svc="$1"
  local cid client admin plugin
  cid="$("${COMPOSE[@]}" ps -q "${svc}")"
  client="$(client_bin_for "${svc}")"
  admin="$(admin_bin_for "${svc}")"
  plugin="$(expected_plugin_for "${svc}")"

  log "[${svc}] server version + auth plugin for user '${USER}' (expect: ${plugin}):"
  docker exec -i "${cid}" "${client}" -u"${USER}" -p"${PASS}" "${DB}" -e \
    "SELECT VERSION() AS version;
     SELECT user, host, plugin FROM mysql.user WHERE user IN ('${USER}','grant_nopass');" \
    2>/dev/null

  # An admin ping as the test user proves the full auth handshake succeeded.
  if docker exec -i "${cid}" "${admin}" ping -u"${USER}" -p"${PASS}" 2>/dev/null | grep -q "is alive"; then
    ok "[${svc}] ${admin} ping OK — '${USER}' authenticated via ${plugin}"
  else
    err "[${svc}] ping/auth FAILED for user '${USER}' (expected ${plugin})"
    return 1
  fi
}

dump_pubkey() {
  local svc="$1"
  local cid
  cid="$("${COMPOSE[@]}" ps -q "${svc}")"
  if [[ "${svc}" == "mariadb" ]]; then
    log "[${svc}] (MariaDB: no caching_sha2 RSA key — uses mysql_native_password)"
    return 0
  fi
  log "[${svc}] RSA public key (/var/lib/mysql/public_key.pem):"
  docker exec -i "${cid}" cat /var/lib/mysql/public_key.pem 2>/dev/null \
    || err "[${svc}] could not read public_key.pem (is the server up?)"
}

print_conn_info() {
  local svc port
  echo
  ok "Connection details for Grant specs:"
  echo "  export CURRENT_ADAPTER=mysql"
  echo "  # NOTE: append ?ssl-mode=disabled to exercise the caching_sha2 RSA"
  echo "  #       full-auth path; without it a TCP connection uses TLS-cleartext."
  for svc in "${SERVICES[@]}"; do
    port="$(host_port_for "${svc}")"
    echo "  # ${svc} ($(expected_plugin_for "${svc}")):"
    echo "  #   mysql://${USER}:${PASS}@127.0.0.1:${port}/${DB}?ssl-mode=disabled"
  done
  echo
  echo "  Example (run specs against MySQL 8.0.x over the RSA full-auth path):"
  echo "    CURRENT_ADAPTER=mysql \\"
  echo "    MYSQL_DATABASE_URL=mysql://${USER}:${PASS}@127.0.0.1:$(host_port_for mysql8046)/${DB}?ssl-mode=disabled \\"
  echo "    crystal spec"
}

cmd_up() {
  local svc rc=0
  log "bringing up: ${SERVICES[*]}"
  "${COMPOSE[@]}" up -d "${SERVICES[@]}"
  for svc in "${SERVICES[@]}"; do
    wait_healthy "${svc}" || rc=1
  done
  for svc in "${SERVICES[@]}"; do
    verify_auth "${svc}" || rc=1
  done
  if (( rc == 0 )); then
    print_conn_info
    ok "MySQL/MariaDB/Percona auth matrix is UP and authenticated: ${SERVICES[*]}"
  else
    err "one or more services failed to come up / authenticate."
  fi
  return "${rc}"
}

cmd_down() {
  log "tearing down ${SERVICES[*]} (with volumes)"
  # Remove only these services + their anonymous volumes.
  "${COMPOSE[@]}" rm -fsv "${SERVICES[@]}" || true
  ok "torn down."
}

cmd_ping() {
  local svc rc=0
  for svc in "${SERVICES[@]}"; do
    verify_auth "${svc}" || rc=1
  done
  return "${rc}"
}

cmd_pubkey() {
  local svc
  for svc in "${SERVICES[@]}"; do
    dump_pubkey "${svc}"
    echo
  done
}

main() {
  case "${1:-up}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    ping)   cmd_ping ;;
    pubkey) cmd_pubkey ;;
    *)
      err "unknown subcommand: ${1:-}"
      echo "usage: $0 {up|down|ping|pubkey}" >&2
      exit 2
      ;;
  esac
}

main "$@"
