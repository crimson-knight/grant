# A program that compresses and expands an encrypted attribute's plaintext
# (the one place Grant uses DEFLATE) and names a constraint and a fixture id
# (the two places it uses CRC-32). `scripts/check_zlib_linkage.rb` builds it
# and requires that the binary links no libz, then runs it.
require "../../src/grant"
require "../../src/grant/encryption"

text = "a value worth compressing " * 40
stored = Grant::Encryption::Compression.encode(text, true, 140)
raise "the value was not compressed" unless stored.starts_with?(Grant::Encryption::Compression::MARKER)
raise "the value did not round-trip" unless Grant::Encryption::Compression.decode(stored) == text
puts "#{text.bytesize} bytes stored as #{stored.bytesize}"
raise "the digest changed" unless Grant::Schema::Naming.digest("123456789") == "cbf43926"
