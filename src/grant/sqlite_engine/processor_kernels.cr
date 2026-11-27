module Grant::SQLiteEngine
  # Tells which instructions the processor running this program has, read
  # once when the program starts, so that each of the engine's hot kernels
  # runs the body that is fastest on this chip. One binary carries every
  # body; the choice is a constant, so a call costs no more than before.
  #
  # - x86-64: CPUID leaves 1, 7 and 0x80000001, plus XCR0 through `xgetbv`
  #   (the operating system must save the vector registers), give the
  #   x86-64-v2, v3 and v4 levels.
  # - Linux on AArch64: the kernel lists the features in the auxiliary
  #   vector (`AT_HWCAP`, `AT_HWCAP2`).
  # - macOS on Apple silicon: the baseline every such processor has
  #   (Advanced SIMD, CRC32, AES, SHA-2), known when the program is compiled.
  # - Anywhere else: none, and every kernel runs its generic body.
  #
  # A program compiled with `-Dgrant_generic_kernels` runs the generic body
  # of every kernel; the benches use it to compare both bodies on one host.
  # Every body gives the same result bit for bit; only the speed differs
  # (spec/grant/sqlite_engine/processor_kernels_spec.cr runs each one the
  # host supports against the generic body).
  module ProcessorKernels
    {% if flag?(:aarch64) && flag?(:linux) %}
      lib LibAuxiliaryVector
        fun getauxval(type : LibC::ULong) : LibC::ULong
      end

      # `AT_HWCAP` and `AT_HWCAP2` and their bits (Linux
      # `arch/arm64/include/uapi/asm/hwcap.h`).
      private HARDWARE_CAPABILITIES_ENTRY        = 16
      private SECOND_HARDWARE_CAPABILITIES_ENTRY = 26
      private ADVANCED_SIMD_CAPABILITY           = 1_u64 << 1
      private AES_CAPABILITY                     = 1_u64 << 3
      private SHA2_CAPABILITY                    = 1_u64 << 6
      private CRC32_CAPABILITY                   = 1_u64 << 7
      private SVE_CAPABILITY                     = 1_u64 << 22
      private SVE2_CAPABILITY                    = 1_u64 << 1

      private def self.has_capability?(capability : UInt64) : Bool
        LibAuxiliaryVector.getauxval(HARDWARE_CAPABILITIES_ENTRY).to_u64 & capability != 0
      end

      private def self.has_second_capability?(capability : UInt64) : Bool
        LibAuxiliaryVector.getauxval(SECOND_HARDWARE_CAPABILITIES_ENTRY).to_u64 & capability != 0
      end
    {% elsif flag?(:x86_64) %}
      # Returns the EAX, EBX, ECX and EDX registers that CPUID gives for
      # *leaf* and *subleaf*.
      private def self.processor_identification(leaf : UInt32, subleaf : UInt32) : {UInt32, UInt32, UInt32, UInt32}
        eax = 0_u32
        ebx = 0_u32
        ecx = 0_u32
        edx = 0_u32
        asm("cpuid" : "={eax}"(eax), "={ebx}"(ebx), "={ecx}"(ecx), "={edx}"(edx) : "{eax}"(leaf), "{ecx}"(subleaf))
        {eax, ebx, ecx, edx}
      end

      private HIGHEST_LEAF          = processor_identification(0_u32, 0_u32)[0]
      private HIGHEST_EXTENDED_LEAF = processor_identification(0x8000_0000_u32, 0_u32)[0]

      # Bit *bit* of *register* (0 EAX, 1 EBX, 2 ECX, 3 EDX) in *leaf*,
      # subleaf 0, or false where the processor has no such leaf.
      private def self.has_bit?(leaf : UInt32, register : Int32, bit : Int32) : Bool
        highest = leaf >= 0x8000_0000_u32 ? HIGHEST_EXTENDED_LEAF : HIGHEST_LEAF
        return false if leaf > highest

        processor_identification(leaf, 0_u32)[register].bit(bit) == 1
      end

      # XCR0, the register that says which register state the operating
      # system saves on a context switch (`xgetbv` with ECX 0). Only read
      # once OSXSAVE (bit 27 of ECX in leaf 1) says `xgetbv` is allowed.
      private def self.extended_control_register : UInt64
        return 0_u64 unless has_bit?(1_u32, 2, 27)

        low = 0_u32
        high = 0_u32
        asm("xgetbv" : "={eax}"(low), "={edx}"(high) : "{ecx}"(0_u32))
        (high.to_u64 << 32) | low.to_u64
      end

      private SAVED_REGISTER_STATE = extended_control_register
    {% end %}

    {% if flag?(:x86_64) %}
      # The x86-64 features the kernels and the levels name, from CPUID.
      # `avx2`, `fma` and the AVX-512 bits count only when XCR0 says the
      # operating system saves the 256-bit (bits 1 and 2) or 512-bit
      # (bits 5, 6 and 7) registers.
      private SAVES_256_BIT_REGISTERS = SAVED_REGISTER_STATE & 0b110 == 0b110
      private SAVES_512_BIT_REGISTERS = SAVES_256_BIT_REGISTERS && SAVED_REGISTER_STATE & 0b1110_0000 == 0b1110_0000

      private def self.list_of_x86_features : Array(String)
        list_of_features = [] of String
        list_of_features << "sse3" if has_bit?(1_u32, 2, 0)
        list_of_features << "pclmulqdq" if has_bit?(1_u32, 2, 1)
        list_of_features << "ssse3" if has_bit?(1_u32, 2, 9)
        list_of_features << "fma" if SAVES_256_BIT_REGISTERS && has_bit?(1_u32, 2, 12)
        list_of_features << "cx16" if has_bit?(1_u32, 2, 13)
        list_of_features << "sse4.1" if has_bit?(1_u32, 2, 19)
        list_of_features << "sse4.2" if has_bit?(1_u32, 2, 20)
        list_of_features << "movbe" if has_bit?(1_u32, 2, 22)
        list_of_features << "popcnt" if has_bit?(1_u32, 2, 23)
        list_of_features << "aes" if has_bit?(1_u32, 2, 25)
        list_of_features << "avx" if SAVES_256_BIT_REGISTERS && has_bit?(1_u32, 2, 28)
        list_of_features << "f16c" if SAVES_256_BIT_REGISTERS && has_bit?(1_u32, 2, 29)
        list_of_features << "lahf" if has_bit?(0x8000_0001_u32, 2, 0)
        list_of_features << "lzcnt" if has_bit?(0x8000_0001_u32, 2, 5)
        list_of_features << "bmi1" if has_bit?(7_u32, 1, 3)
        list_of_features << "avx2" if SAVES_256_BIT_REGISTERS && has_bit?(7_u32, 1, 5)
        list_of_features << "bmi2" if has_bit?(7_u32, 1, 8)
        list_of_features << "erms" if has_bit?(7_u32, 1, 9)
        list_of_features << "avx512f" if SAVES_512_BIT_REGISTERS && has_bit?(7_u32, 1, 16)
        list_of_features << "avx512dq" if SAVES_512_BIT_REGISTERS && has_bit?(7_u32, 1, 17)
        list_of_features << "sha" if has_bit?(7_u32, 1, 29)
        list_of_features << "avx512bw" if SAVES_512_BIT_REGISTERS && has_bit?(7_u32, 1, 30)
        list_of_features << "avx512vl" if SAVES_512_BIT_REGISTERS && has_bit?(7_u32, 1, 31)
        list_of_features << "fsrm" if has_bit?(7_u32, 3, 4)
        list_of_features
      end

      FEATURES = list_of_x86_features
    {% elsif flag?(:aarch64) && flag?(:darwin) %}
      # Every Apple silicon processor has these.
      FEATURES = ["neon", "crc", "aes", "sha2"]
    {% elsif flag?(:aarch64) && flag?(:linux) %}
      private def self.list_of_arm_features : Array(String)
        list_of_features = [] of String
        list_of_features << "neon" if has_capability?(ADVANCED_SIMD_CAPABILITY)
        list_of_features << "crc" if has_capability?(CRC32_CAPABILITY)
        list_of_features << "aes" if has_capability?(AES_CAPABILITY)
        list_of_features << "sha2" if has_capability?(SHA2_CAPABILITY)
        list_of_features << "sve" if has_capability?(SVE_CAPABILITY)
        list_of_features << "sve2" if has_second_capability?(SVE2_CAPABILITY)
        list_of_features
      end

      FEATURES = list_of_arm_features
    {% else %}
      FEATURES = [] of String
    {% end %}

    # The x86-64 microarchitecture levels (the x86-64 psABI): v2 adds
    # SSE3 to SSE4.2, POPCNT, CMPXCHG16B and LAHF; v3 adds AVX, AVX2, BMI1,
    # BMI2, F16C, FMA, LZCNT and MOVBE; v4 adds AVX-512 F, BW, CD-free DQ
    # and VL (the subset the psABI names, CD aside).
    X86_64_V2 = {"sse3", "ssse3", "sse4.1", "sse4.2", "popcnt", "cx16", "lahf"}.all? { |name| FEATURES.includes?(name) }
    X86_64_V3 = X86_64_V2 && {"avx", "avx2", "bmi1", "bmi2", "f16c", "fma", "lzcnt", "movbe"}.all? { |name| FEATURES.includes?(name) }
    X86_64_V4 = X86_64_V3 && {"avx512f", "avx512bw", "avx512dq", "avx512vl"}.all? { |name| FEATURES.includes?(name) }

    # Whether the processor has Advanced SIMD (every AArch64 processor
    # Linux or macOS runs on).
    ADVANCED_SIMD = FEATURES.includes?("neon")

    # The lowercase names of the features found on this processor.
    def self.detected_features : Array(String)
      FEATURES.dup
    end

    # Each kernel's name and the body it runs on this processor. Page and cell
    # copies and byte-string compares call the C library's `memcpy`, `memmove`
    # and `memcmp`, which the C library itself picks for the processor when the
    # program loads (glibc's IFUNC resolvers, libSystem on macOS).
    def self.chosen_variants : Hash(String, String)
      {
        "varint_decode" => Varint.decode_variant,
        "page_copy"     => "libc",
        "key_compare"   => "libc",
      }
    end
  end
end
