require "spec"
require "../../../src/grant/sqlite_engine"

private alias ProcessorKernels = Grant::SQLiteEngine::ProcessorKernels
private alias Varint = Grant::SQLiteEngine::Varint

# Each variant of a kernel, by name, that this host can run, beside the
# generic body; the variants it cannot run are listed as skipped.
private def list_of_varint_variants : Array({String, Proc(Bytes, Int32, Int32, {Int64, Int32})})
  list_of_variants = [] of {String, Proc(Bytes, Int32, Int32, {Int64, Int32})}
  {% if flag?(:x86_64) && compare_versions(Crystal::VERSION, "1.20.0") >= 0 %}
    if ProcessorKernels::X86_64_V3
      list_of_variants << {"x86-64-v3", ->(bytes : Bytes, offset : Int32, limit : Int32) { Varint.decode_long_with_bit_extract(bytes, offset, limit) }}
    else
      STDERR.puts "processor kernels: varint_decode x86-64-v3 skipped (this processor is not x86-64-v3)"
    end
  {% else %}
    STDERR.puts "processor kernels: varint_decode x86-64-v3 skipped (not x86-64, or Crystal before 1.20.0)"
  {% end %}
  list_of_variants
end

# A varint of exactly *length* bytes (1 to 9) with random value bits.
private def random_varint(random : Random, length : Int32) : Bytes
  bytes = Bytes.new(length)
  length.times do |index|
    bits = random.rand(UInt8)
    bytes[index] = index == length - 1 ? (length == 9 ? bits : bits & 0x7f_u8) : bits | 0x80_u8
  end
  bytes
end

describe Grant::SQLiteEngine::ProcessorKernels do
  it "names the features it found and a body for every kernel" do
    STDERR.puts "processor kernels: features #{ProcessorKernels.detected_features.join(' ')}"
    STDERR.puts "processor kernels: chosen #{ProcessorKernels.chosen_variants}"
    ProcessorKernels.detected_features.each { |name| name.should eq(name.downcase) }
    ProcessorKernels.chosen_variants.keys.should eq(["varint_decode", "page_copy", "key_compare"])
    {% if flag?(:grant_generic_kernels) %}
      ProcessorKernels.chosen_variants["varint_decode"].should eq("generic")
    {% end %}
    {% if flag?(:aarch64) %}
      ProcessorKernels.detected_features.should contain("neon")
    {% end %}
  end

  it "names the x86-64 levels in order" do
    ProcessorKernels::X86_64_V2.should be_true if ProcessorKernels::X86_64_V3
    ProcessorKernels::X86_64_V3.should be_true if ProcessorKernels::X86_64_V4
  end

  describe "varint_decode" do
    it "gives the generic body's result in every variant on random varints, offsets and limits" do
      list_of_variants = list_of_varint_variants
      STDERR.puts "processor kernels: varint_decode ran #{(["generic"] + list_of_variants.map(&.[0])).join(", ")}"
      random = Random.new(20261127)
      checked = 0
      2_000.times do
        # A buffer of random bytes with varints of every length at
        # random (unaligned) places, so cuts by the limit land anywhere.
        buffer = Bytes.new(random.rand(0..96)) { random.rand(UInt8) }
        place = 0
        while place < buffer.size
          length = random.rand(1..9)
          break if place + length > buffer.size
          random_varint(random, length).copy_to(buffer[place, length])
          place += length + random.rand(0..3)
        end
        (-1..buffer.size + 1).each do |offset|
          {buffer.size, offset + 1, offset + 8, offset + 9, offset + 10, random.rand(0..buffer.size + 2)}.each do |limit|
            expected = Varint.decode_long(buffer, offset, limit) if 0 <= offset
            list_of_variants.each do |name, variant|
              next unless expected
              variant.call(buffer, offset, limit).should eq(expected), "#{name} at #{offset}, limit #{limit}, #{buffer.hexstring}"
              checked += 1
            end
          end
        end
      end
      STDERR.puts "processor kernels: varint_decode compared #{checked} decodes"
    end

    it "gives the generic body's result on the edge values of every length" do
      list_of_edge_values = [0_i64, 1_i64, 127_i64, 128_i64, 16_383_i64, 16_384_i64, 2_097_151_i64, 2_097_152_i64,
                             268_435_455_i64, 268_435_456_i64, (1_i64 << 35) - 1, 1_i64 << 35, (1_i64 << 42) - 1, 1_i64 << 42,
                             (1_i64 << 49) - 1, 1_i64 << 49, (1_i64 << 56) - 1, 1_i64 << 56, Int64::MAX, Int64::MIN, -1_i64]
      list_of_variants = list_of_varint_variants
      list_of_edge_values.each do |value|
        (0..3).each do |lead|
          buffer = Bytes.new(lead + 9 + 4, 0xff_u8)
          length = Varint.encode(value, buffer, lead)
          expected = Varint.decode_long(buffer, lead, buffer.size)
          expected.should eq({value, length})
          Varint.decode(buffer, lead).should eq({value, length})
          list_of_variants.each do |name, variant|
            variant.call(buffer, lead, buffer.size).should eq(expected), "#{name} for #{value}"
          end
        end
      end
    end
  end
end
