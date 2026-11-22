require "../../spec_helper"
require "../../../src/grant/encryption"
require "compress/zlib"
require "digest/crc32"
require "digest/sha256"
require "json"

private MARKER = Grant::Encryption::Compression::MARKER

# "old data " sixty times, as zlib 1.2.12 wrote it at level 6: what a row
# compressed by Grant 0.25.0 and earlier holds after the marker.
private TEXT_WRITTEN_THROUGH_LIBZ   = "old data " * 60
private STREAM_WRITTEN_THROUGH_LIBZ = "789ccbcf495148492c4954c81f658c32501900ab9eb9dd".hexbytes

private struct VendoredFile
  include JSON::Serializable

  getter path : String = ""
  getter sha256 : String = ""
end

private struct VendoredManifest
  include JSON::Serializable

  getter source : String = ""
  getter commit : String = ""
  getter component : String = ""
  getter namespace : String = ""
  getter list_of_files : Array(VendoredFile) = [] of VendoredFile
end

private VENDOR_ROOT = Path[__DIR__].parent.parent.parent / "src" / "grant" / "vendor"

private def stored_after_marker(stream : Bytes) : String
  String.build do |text|
    text << MARKER
    text.write(stream)
  end
end

describe Grant::Encryption::Compression do
  describe ".encode" do
    it "writes the marker and a zlib stream that libz expands to the value" do
      text = "a value worth compressing " * 40
      stored = Grant::Encryption::Compression.encode(text, true, 140)

      stored.should start_with(MARKER)
      stored.bytesize.should be < text.bytesize // 4
      zlib_stream = IO::Memory.new(stored.to_slice[MARKER.bytesize..])
      Compress::Zlib::Reader.open(zlib_stream, &.gets_to_end).should eq(text)
    end

    it "leaves a value alone below the threshold, without compress: and when it would not shrink" do
      Grant::Encryption::Compression.encode("short", true, 140).should eq("short")
      Grant::Encryption::Compression.encode("long " * 100, false, 140).should eq("long " * 100)
      incompressible = String.new(Random.new(7).random_bytes(200).map { |byte| 0x21_u8 + byte % 94 })
      Grant::Encryption::Compression.encode(incompressible, true, 140).should eq(incompressible)
    end

    it "always compresses a value that starts with the marker" do
      tricky = "#{MARKER}x"
      stored = Grant::Encryption::Compression.encode(tricky, false, 140)

      stored.should_not eq(tricky)
      Grant::Encryption::Compression.decode(stored).should eq(tricky)
    end
  end

  describe ".decode" do
    it "expands a row that an earlier Grant wrote through libz" do
      Grant::Encryption::Compression.decode(stored_after_marker(STREAM_WRITTEN_THROUGH_LIBZ)).should eq(TEXT_WRITTEN_THROUGH_LIBZ)
    end

    it "expands what Compress::Zlib::Writer writes at every level" do
      text = "the same value at every level " * 50
      (0..9).each do |level|
        io = IO::Memory.new
        Compress::Zlib::Writer.open(io, level) { |zlib| zlib << text }
        Grant::Encryption::Compression.decode(stored_after_marker(io.to_slice)).should eq(text)
      end
    end

    it "returns a value without the marker unchanged" do
      Grant::Encryption::Compression.decode("plain text").should eq("plain text")
    end

    it "round-trips an empty value after the marker, binary text and a megabyte" do
      [MARKER, "\u0000ÿ\u{1F600} mixed", "0123456789abcdef" * 65_536].each do |text|
        stored = Grant::Encryption::Compression.encode(text, true, 1)
        Grant::Encryption::Compression.decode(stored).should eq(text)
      end
    end

    it "raises DecryptionError for a stream that is cut short or damaged" do
      cut_short = stored_after_marker(STREAM_WRITTEN_THROUGH_LIBZ[0, 10])
      expect_raises(Grant::Encryption::Cipher::DecryptionError, "The compressed value could not be expanded") do
        Grant::Encryption::Compression.decode(cut_short)
      end

      damaged = STREAM_WRITTEN_THROUGH_LIBZ.dup
      damaged[damaged.size - 1] ^= 0xff_u8
      expect_raises(Grant::Encryption::Cipher::DecryptionError, "The compressed value could not be expanded") do
        Grant::Encryption::Compression.decode(stored_after_marker(damaged))
      end
    end
  end
end

describe "Grant::Schema::Naming.digest" do
  it "is the CRC-32 libz computes, in eight hexadecimal digits" do
    Grant::Schema::Naming.digest("123456789").should eq("cbf43926")
    Grant::Schema::Naming.digest("").should eq("00000000")
    ["a", "price > 0", "lower(email)", "x" * 10_000].each do |text|
      Grant::Schema::Naming.digest(text).should eq(Digest::CRC32.checksum(text).to_s(16).rjust(8, '0'))
    end
  end
end

# The copy of Mica under src/grant/vendor is pinned: each file must hold the
# bytes scripts/vendor_into.rb (in the Mica repository) wrote for the commit
# named in MICA_VENDORED.json.
describe "the vendored copy of Mica" do
  manifest = VendoredManifest.from_json(File.read(VENDOR_ROOT / "MICA_VENDORED.json"))

  it "names its source, a full commit, the deflate component and the Grant::Mica namespace" do
    manifest.source.should eq("https://github.com/amberframework/mica")
    manifest.commit.size.should eq(40)
    manifest.commit.each_char.all? { |character| character.ascii_number? || ('a'..'f').includes?(character) }.should be_true
    manifest.component.should eq("deflate")
    manifest.namespace.should eq("Grant::Mica")
    manifest.list_of_files.should_not be_empty
  end

  it "holds every pinned file with its pinned sha256" do
    manifest.list_of_files.each do |vendored_file|
      observed_sha256 = Digest::SHA256.hexdigest(File.read(VENDOR_ROOT / vendored_file.path))
      fail "src/grant/vendor/#{vendored_file.path} does not match its pin" unless observed_sha256 == vendored_file.sha256
    end
  end

  it "holds no file without a pin" do
    list_of_present = Dir.glob((VENDOR_ROOT / "mica" / "**" / "*.cr").to_s).map { |path| Path[path].relative_to(VENDOR_ROOT).to_s }
    (list_of_present - manifest.list_of_files.map(&.path)).should be_empty
  end
end
