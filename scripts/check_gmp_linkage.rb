#!/usr/bin/ruby
# Proves Grant's default path links no GMP.
#
# Builds the probes in scripts/linkage with $CRYSTAL (default crystal-alpha) and
# counts GMP in each binary: `otool -L` (macOS) or `ldd` (Linux) for the
# linked library, `nm` for __gmp symbols. The default-app and PostgreSQL
# probes must show 0 and 0; the control probe, which requires
# `grant/big_decimal`, must show GMP, so the check is known to be able to
# fail. The SQLite probes are also run, so they must work as well as link.
#
#   /usr/bin/ruby scripts/check_gmp_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]

Probe = Struct.new(:name, :source, :expect_gmp, :run)

PROBES = [
  Probe.new("default app (SQLite)", "scripts/linkage/default_app_probe.cr", false, true),
  Probe.new("PostgreSQL adapter", "scripts/linkage/pg_app_probe.cr", false, false),
  Probe.new("control (BigDecimal)", "scripts/linkage/big_decimal_control_probe.cr", true, true),
]

def count_matches(command, pattern)
  output, status = Open3.capture2e(*command)
  abort "#{command.join(" ")} failed:\n#{output}" unless status.success?
  output.lines.count { |line| line.include?(pattern) }
end

failures = []
Dir.mktmpdir("grant-linkage") do |dir|
  PROBES.each do |probe|
    binary = File.join(dir, File.basename(probe.source, ".cr"))
    output, status = Open3.capture2e(CRYSTAL, "build", "-o", binary, File.join(ROOT, probe.source), chdir: ROOT)
    unless status.success?
      failures << "#{probe.name}: build failed\n#{output}"
      next
    end
    linked = count_matches(LIBRARY_LISTER + [binary], "libgmp")
    symbols = count_matches(["nm", binary], "__gmp")
    shows_gmp = linked > 0 || symbols > 0
    puts format("%-24s linked libgmp: %d   __gmp symbols: %d", probe.name, linked, symbols)
    if shows_gmp != probe.expect_gmp
      failures << "#{probe.name}: expected #{probe.expect_gmp ? "GMP" : "no GMP"}"
    end
    next unless probe.run
    run_output, run_status = Open3.capture2e(binary)
    failures << "#{probe.name}: exited #{run_status.exitstatus}\n#{run_output}" unless run_status.success?
  end
end

if failures.empty?
  puts "GMP-free: OK"
else
  puts failures
  exit 1
end
