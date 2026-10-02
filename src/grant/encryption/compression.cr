require "compress/zlib"

module Grant::Encryption
  # Optional zlib compression applied to the plaintext before encryption, for
  # `encrypts body, compress: true`.
  #
  # The ciphertext layout is unchanged: a compressed plaintext is the marker
  # followed by the zlib stream, inside the same encrypted payload. Reading
  # checks for the marker whether or not the attribute compresses, so turning
  # `compress:` on or off leaves old rows readable. A plaintext that happens to
  # start with the marker is compressed regardless of size, which keeps the
  # round trip exact.
  module Compression
    MARKER = "\u0000\u0001grz"

    # Returns *plain* ready to encrypt: compressed when *compress* is set, the
    # value is at least *threshold* bytes and compression actually shrinks it.
    def self.encode(plain : String, compress : Bool, threshold : Int32) : String
      escape = plain.starts_with?(MARKER)
      return plain unless escape || (compress && plain.bytesize >= threshold)

      io = IO::Memory.new
      io << MARKER
      Compress::Zlib::Writer.open(io) { |zlib| zlib << plain }
      wrapped = String.new(io.to_slice)
      escape || wrapped.bytesize < plain.bytesize ? wrapped : plain
    end

    # Undoes `encode`; values without the marker are returned unchanged.
    def self.decode(stored : String) : String
      return stored unless stored.starts_with?(MARKER)

      body = IO::Memory.new(stored.to_slice[MARKER.bytesize..])
      Compress::Zlib::Reader.open(body, &.gets_to_end)
    end
  end
end
