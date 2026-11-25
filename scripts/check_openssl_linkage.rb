#!/usr/bin/ruby
# Proves a Grant app links no OpenSSL by default.
#
# Builds the probes in scripts/linkage with $CRYSTAL (default crystal-alpha)
# and no flags, then counts OpenSSL in each binary: `otool -L` (macOS) or
# `ldd` (Linux) for libssl and libcrypto, `nm` for EVP_, SSL_ and OPENSSL_
# symbols. The default-app and PostgreSQL probes must show 0 and 0: the
# PostgreSQL driver speaks TLS through Beryl. The PostgreSQL probe built
# with -Duse_openssl (the opt-out kept for one release) must show OpenSSL,
# so the check is known to be able to fail. The SQLite probe is also run,
# so it must work as well as link cleanly.
#
#   /usr/bin/ruby scripts/check_openssl_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]
OPENSSL_LIBRARY = /libssl|libcrypto/
OPENSSL_SYMBOL = /[ _](EVP|SSL|OPENSSL)_/

Probe = Struct.new(:name, :source, :list_of_flags, :expect_openssl, :run)

LIST_OF_PROBES = [
  Probe.new("default app (SQLite)", "scripts/linkage/default_app_probe.cr", [], false, true),
  Probe.new("PostgreSQL adapter", "scripts/linkage/pg_app_probe.cr", [], false, false),
  Probe.new("control (-Duse_openssl)", "scripts/linkage/pg_app_probe.cr", ["-Duse_openssl"], true, false),
]

def count_matches(command, pattern)
  output, status = Open3.capture2e(*command)
  abort "#{command.join(" ")} failed:\n#{output}" unless status.success?
  output.lines.count { |line| line.match?(pattern) }
end

list_of_failures = []
Dir.mktmpdir("grant-openssl-linkage") do |directory|
  LIST_OF_PROBES.each_with_index do |probe, index|
    binary = File.join(directory, "#{File.basename(probe.source, ".cr")}_#{index}")
    output, status = Open3.capture2e(CRYSTAL, "build", *probe.list_of_flags, "-o", binary, File.join(ROOT, probe.source), chdir: ROOT)
    unless status.success?
      list_of_failures << "#{probe.name}: build failed\n#{output}"
      next
    end
    linked = count_matches(LIBRARY_LISTER + [binary], OPENSSL_LIBRARY)
    symbols = count_matches(["nm", binary], OPENSSL_SYMBOL)
    shows_openssl = linked > 0 || symbols > 0
    puts format("%-26s linked libssl/libcrypto: %d   OpenSSL symbols: %d", probe.name, linked, symbols)
    if shows_openssl != probe.expect_openssl
      list_of_failures << "#{probe.name}: expected #{probe.expect_openssl ? "OpenSSL" : "no OpenSSL"}"
    end
    next unless probe.run
    run_output, run_status = Open3.capture2e(binary)
    list_of_failures << "#{probe.name}: exited #{run_status.exitstatus}\n#{run_output}" unless run_status.success?
  end
end

if list_of_failures.empty?
  puts "OpenSSL-free by default: OK"
else
  puts list_of_failures
  exit 1
end
