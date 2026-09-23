require "../src/grant"
require "./parity_generator"

source_path = File.join(Dir.current, "docs", "parity", "parity.json")
source = GrantParity::SourceDocument.from_json(File.read(source_path))
GrantParity::Generator.write(source, Grant::VERSION)

puts "Generated docs/PARITY.md and src/grant/parity.cr for Grant #{Grant::VERSION}."
puts "Generated docs/parity/#{Grant::VERSION}.md snapshot."
puts "Verified code commit: #{source.verified_against_commit}."
