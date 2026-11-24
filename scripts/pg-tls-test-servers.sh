#!/usr/bin/env bash
# Starts the PostgreSQL servers the TLS runs of the pg suite use, each from
# IMAGE (pin it as postgres:<version>@sha256:<digest>):
#
#   port 5432  primary, trust logins, TLS 1.3 only (ssl_min_protocol_version)
#   port 5433  replica database server, scram-sha-256 logins, TLS 1.3 only
#   port 5434  a server limited to TLS 1.2, for the TLS 1.3 error
#
# Every server accepts TLS connections only (pg_hba "hostssl"), so a
# connection that skips TLS fails instead of passing quietly. The server
# certificate names localhost only (so verify-full to 127.0.0.1 must fail)
# and is signed by a CA made here.
#
# Usage: scripts/pg-tls-test-servers.sh IMAGE CERT_DIR
# Prints the environment the specs read. Stop the servers with
#   docker rm -f grant-pg-tls-primary grant-pg-tls-replica grant-pg-tls12
set -euo pipefail

image=$1
cert_dir=$2
mkdir -p "$cert_dir"
cd "$cert_dir"

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=Grant PostgreSQL TLS spec CA" -keyout ca.key -out ca.pem \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
  -subj "/CN=Grant unrelated CA" -keyout unrelated-ca.key -out unrelated-ca.pem \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=localhost" -keyout server.key -out server.csr 2>/dev/null
printf '%s\n' \
  "subjectAltName = DNS:localhost" \
  "keyUsage = critical, digitalSignature" \
  "extendedKeyUsage = serverAuth" \
  "basicConstraints = critical, CA:FALSE" \
  "authorityKeyIdentifier = keyid" > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 30 -extfile server.ext -out server.pem 2>/dev/null
chmod 644 ca.pem server.pem server.key

# The server reads its key only when the postgres user owns it with mode 600,
# so the entrypoint copies the files in before it starts, and writes a
# pg_hba.conf that takes remote logins over TLS only.
start() { # name port auth min-version max-version database
  local name=$1 port=$2 auth=$3 min=$4 max=$5 database=$6
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -p "127.0.0.1:$port:5432" -v "$PWD:/certs:ro" \
    -e POSTGRES_USER=grant -e POSTGRES_PASSWORD=password -e POSTGRES_DB="$database" \
    -e POSTGRES_HOST_AUTH_METHOD="$auth" -e POSTGRES_INITDB_ARGS="--auth-host=$auth" \
    --entrypoint bash "$image" -c "mkdir -p /tls && cp /certs/server.pem /certs/server.key /tls/ \
      && printf 'local all all trust\nhostssl all all all $auth\n' > /tls/pg_hba.conf \
      && chown -R postgres:postgres /tls && chmod 600 /tls/server.key && exec docker-entrypoint.sh postgres \
      -c ssl=on -c ssl_cert_file=/tls/server.pem -c ssl_key_file=/tls/server.key \
      -c ssl_min_protocol_version=$min -c ssl_max_protocol_version=$max \
      -c hba_file=/tls/pg_hba.conf" >/dev/null
}
start grant-pg-tls-primary 5432 trust TLSv1.3 '' grant_db
start grant-pg-tls-replica 5433 scram-sha-256 TLSv1.3 '' grant_replica_db
start grant-pg-tls12 5434 trust TLSv1.2 TLSv1.2 grant_db

for name in grant-pg-tls-primary grant-pg-tls-replica grant-pg-tls12; do
  for _ in $(seq 1 90); do
    if docker exec "$name" pg_isready -h 127.0.0.1 -U grant >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  docker exec "$name" psql -U grant -d postgres -Atc "SELECT version(); SHOW ssl_min_protocol_version; SHOW ssl_max_protocol_version" >&2
done

query="sslmode=verify-full&sslrootcert=$PWD/ca.pem"
echo "PG_DATABASE_URL=postgres://grant@localhost:5432/grant_db?$query"
echo "PG_REPLICA_URL=postgres://grant:password@localhost:5433/grant_replica_db?$query"
echo "GRANT_PG_TLS_PORT=5433"
echo "GRANT_PG_TLS_DATABASE=grant_replica_db"
echo "GRANT_PG_TLS_USER=grant"
echo "GRANT_PG_TLS_PASSWORD=password"
echo "GRANT_PG_TLS_CA_FILE=$PWD/ca.pem"
echo "GRANT_PG_TLS_UNRELATED_CA_FILE=$PWD/unrelated-ca.pem"
echo "GRANT_PG_TLS12_PORT=5434"
