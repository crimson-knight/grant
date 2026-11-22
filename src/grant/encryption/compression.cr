require "../vendor/mica/deflate"

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
  #
  # The zlib stream (RFC 1950) is written and read by Mica's DEFLATE in
  # Crystal (a pinned copy under `Grant::Mica`, see
  # `src/grant/vendor/MICA_VENDORED.json`), so Grant calls no libz. Rows
  # written through libz by an earlier Grant read back unchanged, and an
  # earlier Grant reads the rows written here.
  module Compression
    MARKER = "\u0000\u0001grz"

    # The level `Compress::Zlib::Writer` used by default.
    LEVEL = 6

    # What a stored value may expand to. The stream has passed the payload's
    # authentication by the time it is expanded, so the application wrote it:
    # these are the limits for data a program built itself (1 GiB of output).
    DECODE_LIMITS = Grant::Mica::Deflate::DecodeLimits::TRUSTED_ASSET

    # Returns *plain* ready to encrypt: compressed when *compress* is set, the
    # value is at least *threshold* bytes and compression actually shrinks it.
    def self.encode(plain : String, compress : Bool, threshold : Int32) : String
      escape = plain.starts_with?(MARKER)
      return plain unless escape || (compress && plain.bytesize >= threshold)

      zlib_stream = Grant::Mica::Zlib.encode(plain.to_slice, level: LEVEL)
      wrapped = String.build(MARKER.bytesize + zlib_stream.size) do |text|
        text << MARKER
        text.write(zlib_stream)
      end
      escape || wrapped.bytesize < plain.bytesize ? wrapped : plain
    end

    # Undoes `encode`; values without the marker are returned unchanged.
    # Raises `Cipher::DecryptionError` when the bytes after the marker are
    # not a complete zlib stream.
    def self.decode(stored : String) : String
      return stored unless stored.starts_with?(MARKER)

      zlib_stream = stored.to_slice[MARKER.bytesize..]
      begin
        String.new(Grant::Mica::Zlib.decode(zlib_stream, limits: DECODE_LIMITS, timeout: nil))
      rescue error : Grant::Mica::Error
        raise Cipher::DecryptionError.new("The compressed value could not be expanded: #{error.message}")
      end
    end
  end
end
