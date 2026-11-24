#!/usr/bin/ruby
# Proves a Grant app links no C SQLite library and runs every statement on
# Grant's own engine when it requires `grant/adapter/sqlite/grant_engine`
# (no build flags), or when it is built with -Dgrant_without_libsqlite3.
#
# Builds the default app workload three ways with $CRYSTAL (default
# crystal-alpha) and counts libsqlite3 in each binary: `otool -L` (macOS) or
# `ldd` (Linux) for the linked library, `nm` for its symbols (sqlite3_open_v2,
# sqlite3_step and the like). The two engine builds must show 0 and 0, run to
# the end and report `sqlite_engine: grant`; the control build
# (`grant/adapter/sqlite`, no flag) must show libsqlite3 and report
# `sqlite_engine: libsqlite3`, so the check is known to be able to fail.
#
#   /usr/bin/ruby scripts/check_sqlite3_linkage.rb
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
CRYSTAL = ENV.fetch("CRYSTAL", "crystal-alpha")
LIBRARY_LISTER = RUBY_PLATFORM.include?("darwin") ? %w[otool -L] : %w[ldd]
DEFAULT_PROBE = "scripts/linkage/default_app_probe.cr"
GRANT_ENGINE_PROBE = "scripts/linkage/grant_engine_app_probe.cr"

Build = Struct.new(:name, :probe, :flags, :expect_libsqlite3)

BUILDS = [
  Build.new("grant_engine require, no flags", GRANT_ENGINE_PROBE, [], false),
  Build.new("-Dgrant_without_libsqlite3", DEFAULT_PROBE, ["-Dgrant_without_libsqlite3"], false),
  Build.new("control (libsqlite3)", DEFAULT_PROBE, [], true),
]
SQLITE_SYMBOL = /\s_?sqlite3_(open_v2|prepare_v2|step|finalize|libversion)(@.*)?$/

def count_matches(command, pattern)
  output, status = Open3.capture2e(*command)
  abort "#{command.join(" ")} failed:\n#{output}" unless status.success?
  output.lines.count { |line| line.match?(pattern) }
end

failures = []
Dir.mktmpdir("grant-linkage") do |dir|
  BUILDS.each_with_index do |build, index|
    binary = File.join(dir, "default_app_probe_#{index}")
    output, status = Open3.capture2e(CRYSTAL, "build", *build.flags, "-o", binary, File.join(ROOT, build.probe), chdir: ROOT)
    unless status.success?
      failures << "#{build.name}: build failed\n#{output}"
      next
    end
    linked = count_matches(LIBRARY_LISTER + [binary], /libsqlite3/)
    symbols = count_matches(["nm", binary], SQLITE_SYMBOL)
    shows_libsqlite3 = linked > 0 || symbols > 0
    puts format("%-32s linked libsqlite3: %d   libsqlite3 symbols: %d", build.name, linked, symbols)
    if shows_libsqlite3 != build.expect_libsqlite3
      failures << "#{build.name}: expected #{build.expect_libsqlite3 ? "libsqlite3" : "no libsqlite3"}"
    end
    run_output, run_status = Open3.capture2e(binary)
    failures << "#{build.name}: exited #{run_status.exitstatus}\n#{run_output}" unless run_status.success?
    expected_engine = build.expect_libsqlite3 ? "libsqlite3" : "grant"
    unless run_output.include?("sqlite_engine: #{expected_engine}")
      failures << "#{build.name}: expected sqlite_engine: #{expected_engine}"
    end
    File.write(File.join(ENV["LINKAGE_OUTPUT_DIR"], "#{File.basename(binary)}.txt"), run_output) if ENV["LINKAGE_OUTPUT_DIR"]
  end
end

if failures.empty?
  puts "libsqlite3-free: OK"
else
  puts failures
  exit 1
end
