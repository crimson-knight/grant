#!/usr/bin/ruby
# Proves Grant's default path links no GMP.
#
# Builds the probes in scripts/linkage with $CRYSTAL (default crystal-alpha) and
# counts GMP in each binary: `otool -L` (macOS) or `ldd` (Linux) for the
# linked library, `nm` for __gmp symbols. The default-app and PostgreSQL
# probes must show 0 and 0. The SQLite probes are also run, so they must work
# as well as link.
#
# What the BigDecimal probe (`grant/big_decimal`) must show depends on the
# compiler's stdlib, which the script reads from the compiler itself
# (`$CRYSTAL env CRYSTAL_PATH`) and prints as the detected mode:
#
# - pure engine: a stdlib with `crystal/big_num.cr` and `big/gmp/` (the
#   crystal-alpha fork after 1.22.3-incremental-4) runs BigInt, BigFloat,
#   BigRational and BigDecimal on pure Crystal. The BigDecimal probe must show
#   0 and 0, and the same probe built with `-Duse_gmp` is the control that
#   must show GMP, so the check is known to be able to fail.
# - GMP stdlib: stock Crystal and released crystal-alpha up to
#   1.22.3-incremental-4, whose `big` links GMP. The BigDecimal probe is the
#   control and must show GMP.
#
#   /usr/bin/ruby scripts/check_gmp_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]
BIG_DECIMAL_PROBE = "scripts/linkage/big_decimal_control_probe.cr"

Probe = Struct.new(:name, :source, :flags, :expect_gmp, :run)

# True when one of the compiler's stdlib roots carries the pure `Crystal::BigNum`
# engine, with GMP kept behind `-Duse_gmp` in `big/gmp/`.
def pure_big_engine?
  output, status = Open3.capture2e(CRYSTAL, "env", "CRYSTAL_PATH", chdir: ROOT)
  abort "#{CRYSTAL} env CRYSTAL_PATH failed:\n#{output}" unless status.success?
  output.strip.split(File::PATH_SEPARATOR).any? do |path|
    root = File.expand_path(path, ROOT)
    File.file?(File.join(root, "crystal", "big_num.cr")) && File.directory?(File.join(root, "big", "gmp"))
  end
end

PURE_ENGINE = pure_big_engine?

BIG_DECIMAL_PROBES =
  if PURE_ENGINE
    [
      Probe.new("BigDecimal (pure)", BIG_DECIMAL_PROBE, [], false, true),
      Probe.new("control (-Duse_gmp)", BIG_DECIMAL_PROBE, ["-Duse_gmp"], true, true),
    ]
  else
    [Probe.new("control (BigDecimal)", BIG_DECIMAL_PROBE, [], true, true)]
  end

PROBES = [
  Probe.new("default app (SQLite)", "scripts/linkage/default_app_probe.cr", [], false, true),
  Probe.new("PostgreSQL adapter", "scripts/linkage/pg_app_probe.cr", [], false, false),
] + BIG_DECIMAL_PROBES

def count_matches(command, pattern)
  output, status = Open3.capture2e(*command)
  abort "#{command.join(" ")} failed:\n#{output}" unless status.success?
  output.lines.count { |line| line.include?(pattern) }
end

if PURE_ENGINE
  puts "mode: pure engine (stdlib has crystal/big_num.cr and big/gmp/); BigDecimal expects no GMP, -Duse_gmp is the control"
else
  puts "mode: GMP stdlib (no pure big engine); BigDecimal is the control and expects GMP"
end

failures = []
Dir.mktmpdir("grant-linkage") do |dir|
  PROBES.each_with_index do |probe, index|
    binary = File.join(dir, "#{index}_#{File.basename(probe.source, ".cr")}")
    command = [CRYSTAL, "build", *probe.flags, "-o", binary, File.join(ROOT, probe.source)]
    output, status = Open3.capture2e(*command, chdir: ROOT)
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
