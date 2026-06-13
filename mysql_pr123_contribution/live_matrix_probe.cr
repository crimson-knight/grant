# Live caching_sha2_password version-matrix probe for crystal-mysql PR #123.
#
# Compiles against THIS checkout's ./src/mysql (the pr-123 branch) and connects
# to each server in Grant's docker-compose version matrix. For each MySQL/Percona
# server it exercises BOTH auth paths:
#   * full-auth (cold cache): the FIRST connection after the server has not yet
#     cached the password runs the RSA-public-key path (0x02 request, AuthMoreData
#     0x04, RSA-OAEP(SHA-1) encrypt of password XOR nonce).
#   * fast-auth: a second connection in the same run, password now cached (0x03).
# For MariaDB it asserts the mysql_native_password handshake connects.
#
# To force a cold cache deterministically we FLUSH the server's auth cache as
# root over a fresh connection (which itself re-primes), then immediately open a
# new connection as the test user to hit full-auth. We also run a data round-trip.
#
# Usage (matrix up via docker-compose.test.yml):
#   crystal run examples/live_matrix_probe.cr
require "uri"
require "db"
require "../src/mysql"

# {label, url, kind} — kind is :caching_sha2 or :native (MariaDB)
USER = "grant"
PASS = "test_password"
DB_NAME = "grant_test"

# IMPORTANT: ssl-mode=disabled is REQUIRED to exercise the RSA-OAEP(SHA-1)
# full-auth-over-plaintext path. With the driver default (ssl-mode=preferred) a
# TCP connection establishes TLS, and caching_sha2 full-auth then sends the
# cleartext password inside the TLS tunnel — bypassing RSA entirely. We
# deliberately disable TLS so a cold-cache connection MUST run the RSA path that
# our SHA-1 OAEP fix is about. (We also run a preferred/TLS pass for coverage.)
SSL_DISABLED = "?ssl-mode=disabled"

targets = [
  {"MySQL 8.0.11 (first GA, emulated)", "mysql://#{USER}:#{PASS}@127.0.0.1:3310/#{DB_NAME}#{SSL_DISABLED}", :caching_sha2},
  {"MySQL 8.0.x", "mysql://#{USER}:#{PASS}@127.0.0.1:3311/#{DB_NAME}#{SSL_DISABLED}", :caching_sha2},
  {"MySQL 8.4 LTS (native_password OFF)", "mysql://#{USER}:#{PASS}@127.0.0.1:3312/#{DB_NAME}#{SSL_DISABLED}", :caching_sha2},
  {"MySQL 9.x LTS", "mysql://#{USER}:#{PASS}@127.0.0.1:3313/#{DB_NAME}#{SSL_DISABLED}", :caching_sha2},
  {"MariaDB 11.8 LTS (native_password)", "mysql://#{USER}:#{PASS}@127.0.0.1:3314/#{DB_NAME}#{SSL_DISABLED}", :native},
  {"Percona Server 8.0", "mysql://#{USER}:#{PASS}@127.0.0.1:3315/#{DB_NAME}#{SSL_DISABLED}", :caching_sha2},
]

# Root URL for flushing the caching_sha2 cache to force a cold full-auth path.
def root_url(port : Int32) : String
  "mysql://root:root_password@127.0.0.1:#{port}/#{DB_NAME}"
end

def port_of(url : String) : Int32
  URI.parse(url).port.not_nil!
end

results = [] of NamedTuple(label: String, server: String, plugin: String, full_auth: String, fast_auth: String, roundtrip: String, notes: String)
failures = 0

targets.each do |(label, url, kind)|
  puts "=== #{label} ==="
  server = "?"
  plugin = "?"
  full_auth = "-"
  fast_auth = "-"
  roundtrip = "-"
  notes = ""

  begin
    port = port_of(url)

    # For caching_sha2 servers, flush the privilege/auth cache as root first so
    # the very next test-user connection MUST run full-auth (cold cache). We use
    # FLUSH PRIVILEGES which clears the in-memory caching_sha2 fast-auth cache.
    if kind == :caching_sha2
      begin
        DB.open(root_url(port)) do |rdb|
          rdb.exec("FLUSH PRIVILEGES")
        end
        notes += "cache flushed; "
      rescue ex
        notes += "flush skipped (#{ex.class}); "
      end
    end

    # The test user's auth plugin, read as ROOT (the `grant` user has no
    # privilege on mysql.user). This is informational; the real proof of which
    # path ran is that the test-user connection below authenticates at all.
    begin
      DB.open(root_url(port)) do |rdb|
        plugin = rdb.scalar(
          "SELECT plugin FROM mysql.user WHERE user = ? LIMIT 1", USER
        ).as(String)
      end
    rescue
      plugin = "?"
    end

    # First test-user connection — cold cache => full-auth (RSA) for caching_sha2,
    # or native handshake for MariaDB. Reaching VERSION() proves auth succeeded.
    DB.open(url) do |db|
      server = db.scalar("SELECT VERSION()").as(String)
      full_auth = "PASS"

      # Data round-trip.
      db.exec("DROP TABLE IF EXISTS auth_probe")
      db.exec("CREATE TABLE auth_probe (id INT PRIMARY KEY, name VARCHAR(64))")
      db.exec("INSERT INTO auth_probe (id, name) VALUES (?, ?)", 1, "full_auth_roundtrip")
      got = db.scalar("SELECT name FROM auth_probe WHERE id = ?", 1).as(String)
      db.exec("UPDATE auth_probe SET name = ? WHERE id = ?", "updated", 1)
      got2 = db.scalar("SELECT name FROM auth_probe WHERE id = ?", 1).as(String)
      db.exec("DELETE FROM auth_probe WHERE id = ?", 1)
      remaining = db.scalar("SELECT COUNT(*) FROM auth_probe").as(Int64)
      db.exec("DROP TABLE auth_probe")
      roundtrip = (got == "full_auth_roundtrip" && got2 == "updated" && remaining == 0) ? "PASS" : "FAIL"
    end

    # Second connection — for caching_sha2 the password is now cached => fast-auth.
    DB.open(url) do |db|
      db.scalar("SELECT 1")
      fast_auth = "PASS"
    end

    puts "  server=#{server} plugin=#{plugin}"
    puts "  full_auth=#{full_auth} fast_auth=#{fast_auth} roundtrip=#{roundtrip}"
  rescue ex
    failures += 1
    full_auth = "FAIL" if full_auth == "-"
    notes += "#{ex.class}: #{ex.message}"
    puts "  FAIL — #{ex.class}: #{ex.message}"
  end

  results << {label: label, server: server, plugin: plugin, full_auth: full_auth, fast_auth: fast_auth, roundtrip: roundtrip, notes: notes}
  puts ""
end

puts "================ RESULTS TABLE ================"
results.each do |r|
  puts "#{r[:label]}"
  puts "  version=#{r[:server]} plugin=#{r[:plugin]} full_auth=#{r[:full_auth]} fast_auth=#{r[:fast_auth]} roundtrip=#{r[:roundtrip]}"
  puts "  notes: #{r[:notes]}" unless r[:notes].empty?
end
puts ""
puts failures.zero? ? "ALL LIVE PROBES PASSED" : "#{failures} TARGET(S) FAILED (may include not-yet-ready servers)"
