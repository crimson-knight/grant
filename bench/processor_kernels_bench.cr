# Times each body of the SQLite engine's processor kernels on this host:
# the generic body against every variant the processor supports, median of
# ROUNDS rounds, in nanoseconds per call.
#
#   crystal build --release bench/processor_kernels_bench.cr -o kernels_bench
#   ./kernels_bench [ROUNDS]
#
# Prints the features found, the body each kernel chose, and one line per
# kernel, workload and body: "kernel workload body ns_per_call".
require "../src/grant/sqlite_engine"

module ProcessorKernelsBench
  alias Varint = Grant::SQLiteEngine::Varint

  DECODES_PER_ROUND = 4_000_000

  # Varints laid end to end, each of a length drawn from *list_of_lengths*,
  # and the offset of each.
  def self.varint_buffer(list_of_lengths : Array(Int32), random : Random) : {Bytes, Array(Int32)}
    io = IO::Memory.new
    list_of_offsets = [] of Int32
    65_536.times do
      length = list_of_lengths.sample(random)
      low = length == 1 ? 0_i64 : 1_i64 << (7 * (length - 1))
      high = length >= 9 ? Int64::MAX : (1_i64 << (7 * length)) - 1
      value = random.rand(low..high)
      scratch = Bytes.new(9)
      used = Varint.encode(value, scratch, 0)
      list_of_offsets << io.pos.to_i32
      io.write(scratch[0, used])
    end
    io.write(Bytes.new(16))
    {io.to_slice, list_of_offsets}
  end

  def self.time_decodes(buffer : Bytes, list_of_offsets : Array(Int32), & : Bytes, Int32, Int32 -> {Int64, Int32}) : Float64
    checksum = 0_i64
    count = list_of_offsets.size
    started = Time.instant
    index = 0
    DECODES_PER_ROUND.times do
      value, length = yield buffer, list_of_offsets.unsafe_fetch(index), buffer.size
      checksum &+= value &+ length
      index += 1
      index = 0 if index == count
    end
    elapsed = (Time.instant - started).total_nanoseconds
    raise "checksum" if checksum == 42
    elapsed / DECODES_PER_ROUND
  end

  def self.median(list_of_values : Array(Float64)) : Float64
    sorted = list_of_values.sort
    (sorted[(sorted.size - 1) // 2] + sorted[sorted.size // 2]) / 2
  end

  def self.run(rounds : Int32) : Nil
    STDOUT.puts "features: #{Grant::SQLiteEngine::ProcessorKernels.detected_features.join(' ')}"
    STDOUT.puts "chosen: #{Grant::SQLiteEngine::ProcessorKernels.chosen_variants}"
    random = Random.new(20261127)
    {
      "rowids_3_bytes" => [3],
      "lengths_2_to_4" => [2, 3, 4],
      "lengths_2_to_9" => [2, 3, 4, 5, 6, 7, 8, 9],
    }.each do |workload, list_of_lengths|
      buffer, list_of_offsets = varint_buffer(list_of_lengths, random)
      bodies = {} of String => Array(Float64)
      rounds.times do
        (bodies["generic"] ||= [] of Float64) << time_decodes(buffer, list_of_offsets) { |bytes, offset, limit| Varint.decode_long(bytes, offset, limit) }
        {% if flag?(:x86_64) && compare_versions(Crystal::VERSION, "1.20.0") >= 0 %}
          if Grant::SQLiteEngine::ProcessorKernels::X86_64_V3
            (bodies["x86-64-v3"] ||= [] of Float64) << time_decodes(buffer, list_of_offsets) { |bytes, offset, limit| Varint.decode_long_with_bit_extract(bytes, offset, limit) }
          end
        {% end %}
      end
      bodies.each do |body, list_of_times|
        STDOUT.puts "varint_decode #{workload} #{body} #{median(list_of_times).round(3)} (#{list_of_times.map(&.round(3)).join(' ')})"
      end
    end
  end
end

ProcessorKernelsBench.run((ARGV[0]? || "6").to_i)
