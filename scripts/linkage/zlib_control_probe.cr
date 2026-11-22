# The control for `scripts/check_zlib_linkage.rb`: a program that uses the
# standard library's Compress::Zlib must show libz, which proves the check
# can fail.
require "compress/zlib"

io = IO::Memory.new
Compress::Zlib::Writer.open(io) { |zlib| zlib << "control" }
puts Compress::Zlib::Reader.open(io.rewind, &.gets_to_end)
