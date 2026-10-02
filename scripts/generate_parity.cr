require "../src/grant"
require "./parity_generator"

source_path = File.join(Dir.current, "docs", "parity", "parity.json")
source = GrantParity::SourceDocument.from_json(File.read(source_path))
refresh_snapshot = ARGV.delete("--refresh-snapshot") != nil
raise "Unknown parity generator arguments: #{ARGV.join(" ")}" unless ARGV.empty?

GrantParity::Generator.write(source, Grant::VERSION, Dir.current, refresh_snapshot)

puts "Generated docs/PARITY.md and src/grant/parity.cr for Grant #{Grant::VERSION}."
puts "#{refresh_snapshot ? "Refreshed" : "Generated"} docs/parity/#{Grant::VERSION}.md snapshot."
puts "Verified code commit: #{source.verified_against_commit}."
