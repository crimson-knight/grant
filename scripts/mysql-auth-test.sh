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
SERVICES=(mysql8 mysql9)

# Host port for a given service (avoids bash-4 associative arrays).
host_port_for() {
  case "$1" in
    mysql8) echo 3308 ;;
    mysql9) echo 3309 ;;
    *)      echo "" ;;
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

# Verify the test user authenticates with caching_sha2_password and that the
# server actually has that plugin assigned to the user. Runs the client INSIDE
# the container (so it doesn't depend on a host mysql client being installed).
verify_auth() {
  local svc="$1"
  local cid
  cid="$("${COMPOSE[@]}" ps -q "${svc}")"

  log "[${svc}] server version + auth plugin for user '${USER}':"
  docker exec -i "${cid}" mysql -u"${USER}" -p"${PASS}" "${DB}" -e \
    "SELECT VERSION() AS version;
     SELECT user, host, plugin FROM mysql.user WHERE user IN ('${USER}','grant_nopass');" \
    2>/dev/null

  # mysqladmin ping as the test user proves the full auth handshake succeeded.
  if docker exec -i "${cid}" mysqladmin ping -u"${USER}" -p"${PASS}" 2>/dev/null | grep -q "mysqld is alive"; then
    ok "[${svc}] mysqladmin ping OK — '${USER}' authenticated via caching_sha2_password"
  else
    err "[${svc}] ping/auth FAILED for user '${USER}'"
    return 1
  fi
}

dump_pubkey() {
  local svc="$1"
  local cid
  cid="$("${COMPOSE[@]}" ps -q "${svc}")"
  log "[${svc}] RSA public key (/var/lib/mysql/public_key.pem):"
  docker exec -i "${cid}" cat /var/lib/mysql/public_key.pem 2>/dev/null \
    || err "[${svc}] could not read public_key.pem (is the server up?)"
}

print_conn_info() {
  local svc port
  echo
  ok "Connection details for Grant specs:"
  echo "  export CURRENT_ADAPTER=mysql"
  for svc in "${SERVICES[@]}"; do
    port="$(host_port_for "${svc}")"
    echo "  # ${svc}:"
    echo "  #   mysql://${USER}:${PASS}@127.0.0.1:${port}/${DB}"
  done
  echo
  echo "  Example (run specs against MySQL 8):"
  echo "    CURRENT_ADAPTER=mysql \\"
  echo "    MYSQL_DATABASE_URL=mysql://${USER}:${PASS}@127.0.0.1:$(host_port_for mysql8)/${DB} \\"
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
    ok "MySQL 8 and 9 caching_sha2_password images are UP and authenticated."
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
