#!/usr/bin/ruby
# Proves Grant's default path links no PCRE2.
#
# Builds the probes in spec/linkage with $CRYSTAL (default crystal-alpha) and
# counts PCRE2 in each binary: `otool -L` (macOS) or `ldd` (Linux) for the
# linked library, `nm` for pcre2_ symbols. The default-app and PostgreSQL
# probes must show 0 and 0; the control probe, which uses a Regex, must show
# PCRE2, so the check is known to be able to fail. The SQLite probe is also
# run, so it must work as well as link cleanly.
#
#   /usr/bin/ruby scripts/check_pcre2_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]

Probe = Struct.new(:name, :source, :expect_pcre2, :run)

PROBES = [
  Probe.new("default app (SQLite)", "spec/linkage/default_app_probe.cr", false, true),
  Probe.new("PostgreSQL adapter", "spec/linkage/pg_app_probe.cr", false, false),
  Probe.new("control (uses Regex)", "spec/linkage/regex_control_probe.cr", true, true),
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
    linked = count_matches(LIBRARY_LISTER + [binary], "pcre2")
    symbols = count_matches(["nm", binary], "pcre2_")
    shows_pcre2 = linked > 0 || symbols > 0
    puts format("%-24s linked libpcre2: %d   pcre2_ symbols: %d", probe.name, linked, symbols)
    if shows_pcre2 != probe.expect_pcre2
      failures << "#{probe.name}: expected #{probe.expect_pcre2 ? "PCRE2" : "no PCRE2"}"
    end
    next unless probe.run
    run_output, run_status = Open3.capture2e(binary)
    failures << "#{probe.name}: exited #{run_status.exitstatus}\n#{run_output}" unless run_status.success?
  end
end

if failures.empty?
  puts "PCRE2-free: OK"
else
  puts failures
  exit 1
end
