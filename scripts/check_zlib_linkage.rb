#!/usr/bin/ruby
# Proves an app on Grant built with -Dwithout_zlib links no libz, with
# encrypted attributes that compress, index names and fixture ids included.
# (Without the flag the standard library's HTTP code, which Grant's
# middleware requires, reaches libz by itself.)
#
# Builds the probes in scripts/linkage with $CRYSTAL (default crystal-alpha) and
# counts libz in each binary: `otool -L` (macOS) or `ldd` (Linux) for the
# linked library, `nm` for libz's symbols
# (inflateInit2_, deflateInit2_, crc32 and the like). The
# default-app and compressed-encryption probes must show 0 and 0; the control
# probe, which uses the standard library's Compress::Zlib, must show libz, so
# the check is known to be able to fail. Both Grant probes are also run, so
# they must work as well as link cleanly.
#
#   /usr/bin/ruby scripts/check_zlib_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]

Probe = Struct.new(:name, :source, :expect_zlib, :run)

PROBES = [
  Probe.new("default app (SQLite)", "scripts/linkage/default_app_probe.cr", false, true),
  Probe.new("compressed encryption", "scripts/linkage/compressed_encryption_probe.cr", false, true),
  Probe.new("control (Compress::Zlib)", "scripts/linkage/zlib_control_probe.cr", true, true),
]
ZLIB_SYMBOL = /\s_?(inflate|deflate|crc32|adler32)(Init2?_|End|Reset)?(@.*)?$/

def count_matches(command, pattern)
  output, status = Open3.capture2e(*command)
  abort "#{command.join(" ")} failed:\n#{output}" unless status.success?
  output.lines.count { |line| line.match?(pattern) }
end

failures = []
Dir.mktmpdir("grant-linkage") do |dir|
  PROBES.each do |probe|
    binary = File.join(dir, File.basename(probe.source, ".cr"))
    output, status = Open3.capture2e(CRYSTAL, "build", "-Dwithout_zlib", "-o", binary, File.join(ROOT, probe.source), chdir: ROOT)
    unless status.success?
      failures << "#{probe.name}: build failed\n#{output}"
      next
    end
    linked = count_matches(LIBRARY_LISTER + [binary], /libz\./)
    symbols = count_matches(["nm", binary], ZLIB_SYMBOL)
    shows_zlib = linked > 0 || symbols > 0
    puts format("%-26s linked libz: %d   libz symbols: %d", probe.name, linked, symbols)
    if shows_zlib != probe.expect_zlib
      failures << "#{probe.name}: expected #{probe.expect_zlib ? "libz" : "no libz"}"
    end
    next unless probe.run
    run_output, run_status = Open3.capture2e(binary)
    failures << "#{probe.name}: exited #{run_status.exitstatus}\n#{run_output}" unless run_status.success?
  end
end

if failures.empty?
  puts "libz-free: OK"
else
  puts failures
  exit 1
end
