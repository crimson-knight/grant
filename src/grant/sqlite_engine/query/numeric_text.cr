module Grant::SQLiteEngine::Query
  # SQLite's conversions between numbers and text, ported from the 3.51.0
  # sources (util.c `sqlite3AtoF`, `sqlite3Atoi64`, `sqlite3FpDecode`, and
  # printf.c's `%!.15g`), so a value converts exactly as C SQLite converts it,
  # including where that differs from correctly rounded IEEE 754 conversion.
  module NumericText
    LARGEST_UINT64 = UInt64::MAX
    SMALLEST_INT64 = Int64::MIN
    LARGEST_INT64  = Int64::MAX

    # Result of `ato_f`: the value and SQLite's verdict on the text.
    #
    # * 1: the whole text is an integer
    # * 2 or more: the whole text is a number with a decimal point or exponent
    # * 0: not a number (the value is that of any valid prefix)
    # * -1: not a number, but a prefix with a decimal point or exponent is
    record RealParse, value : Float64, kind : Int32

    # Result of `atoi64`: the value (clamped) and SQLite's code: 0 the whole
    # text is an integer that fits, 1 extra text follows the digits, 2 too
    # large, 3 exactly 9223372036854775808, -1 no digits at all.
    record IntegerParse, value : Int64, code : Int32

    # sqlite3Isspace: space, tab, newline, vertical tab, form feed, return.
    @[AlwaysInline]
    def self.space?(byte : UInt8) : Bool
      byte == 0x20_u8 || (byte >= 0x09_u8 && byte <= 0x0d_u8)
    end

    @[AlwaysInline]
    def self.digit?(byte : UInt8) : Bool
      byte >= 0x30_u8 && byte <= 0x39_u8
    end

    def self.ato_f(text : String) : RealParse
      ato_f(text.to_slice)
    end

    # sqlite3AtoF for UTF-8 bytes.
    def self.ato_f(bytes : Bytes) : RealParse
      return RealParse.new(0.0, 0) if bytes.empty?
      finish = bytes.size
      position = 0
      sign = 1
      significand = 0_u64
      shift = 0
      exponent_sign = 1
      exponent = 0
      exponent_valid = true
      digit_count = 0
      kind = 1
      while position < finish && space?(bytes.unsafe_fetch(position))
        position += 1
      end
      return RealParse.new(0.0, 0) if position >= finish
      byte = bytes.unsafe_fetch(position)
      if byte == '-'.ord
        sign = -1
        position += 1
      elsif byte == '+'.ord
        position += 1
      end
      limit = (LARGEST_UINT64 - 9) // 10
      while position < finish && digit?(bytes.unsafe_fetch(position))
        significand = significand * 10 + (bytes.unsafe_fetch(position) - 0x30_u8)
        position += 1
        digit_count += 1
        if significand >= limit
          while position < finish && digit?(bytes.unsafe_fetch(position))
            position += 1
            shift += 1
          end
        end
      end
      if position < finish
        if bytes.unsafe_fetch(position) == '.'.ord
          position += 1
          kind += 1
          while position < finish && digit?(bytes.unsafe_fetch(position))
            if significand < limit
              significand = significand * 10 + (bytes.unsafe_fetch(position) - 0x30_u8)
              shift -= 1
              digit_count += 1
            end
            position += 1
          end
        end
        if position < finish
          byte = bytes.unsafe_fetch(position)
          if byte == 'e'.ord || byte == 'E'.ord
            position += 1
            exponent_valid = false
            kind += 1
            if position < finish
              byte = bytes.unsafe_fetch(position)
              if byte == '-'.ord
                exponent_sign = -1
                position += 1
              elsif byte == '+'.ord
                position += 1
              end
              while position < finish && digit?(bytes.unsafe_fetch(position))
                exponent = exponent < 10_000 ? exponent * 10 + (bytes.unsafe_fetch(position) - 0x30_u8).to_i32 : 10_000
                position += 1
                exponent_valid = true
              end
            end
          end
          while position < finish && space?(bytes.unsafe_fetch(position))
            position += 1
          end
        end
      end
      value = significand_to_real(significand, exponent * exponent_sign + shift, sign)
      verdict = if position == finish && digit_count > 0 && exponent_valid && kind > 0
                  kind
                elsif kind >= 2 && (kind == 3 || exponent_valid) && digit_count > 0
                  -1
                else
                  0
                end
      RealParse.new(value, verdict)
    end

    # The do_atof_calc block of sqlite3AtoF: significand × 10^exponent in
    # double-double arithmetic.
    private def self.significand_to_real(significand : UInt64, exponent : Int32, sign : Int32) : Float64
      return sign < 0 ? -0.0 : 0.0 if significand == 0
      while exponent > 0 && significand < (LARGEST_UINT64 - 0x7ff) // 10
        significand *= 10
        exponent -= 1
      end
      while exponent < 0 && significand % 10 == 0
        significand //= 10
        exponent += 1
      end
      high = significand.to_f64
      low = 0.0
      if high <= 18446744073709549568.0
        rounded = high.to_u64!
        low = significand >= rounded ? (significand - rounded).to_f64 : -((rounded - significand).to_f64)
      end
      if exponent > 0
        while exponent >= 100
          exponent -= 100
          high, low = dekker_multiply(high, low, 1.0e+100, -1.5902891109759918046e+83)
        end
        while exponent >= 10
          exponent -= 10
          high, low = dekker_multiply(high, low, 1.0e+10, 0.0)
        end
        while exponent >= 1
          exponent -= 1
          high, low = dekker_multiply(high, low, 1.0e+01, 0.0)
        end
      else
        while exponent <= -100
          exponent += 100
          high, low = dekker_multiply(high, low, 1.0e-100, -1.99918998026028836196e-117)
        end
        while exponent <= -10
          exponent += 10
          high, low = dekker_multiply(high, low, 1.0e-10, -3.6432197315497741579e-27)
        end
        while exponent <= -1
          exponent += 1
          high, low = dekker_multiply(high, low, 1.0e-01, -5.5511151231257827021e-18)
        end
      end
      result = high + low
      result = Float64::INFINITY if result.nan?
      sign < 0 ? -result : result
    end

    # dekkerMul2: (high, low) × (y, yy) in double-double arithmetic
    # (T. J. Dekker, 1971).
    @[AlwaysInline]
    private def self.dekker_multiply(high : Float64, low : Float64, y : Float64, yy : Float64) : {Float64, Float64}
      mask = 0xfffffffffc000000_u64
      hx = (high.unsafe_as(UInt64) & mask).unsafe_as(Float64)
      tx = high - hx
      hy = (y.unsafe_as(UInt64) & mask).unsafe_as(Float64)
      ty = y - hy
      p = hx * hy
      q = hx * ty + tx * hy
      c = p + q
      cc = p - c + q + tx * ty
      cc = high * yy + low * y + cc
      new_high = c + cc
      new_low = c - new_high
      new_low += cc
      {new_high, new_low}
    end

    def self.atoi64(text : String) : IntegerParse
      atoi64(text.to_slice)
    end

    # sqlite3Atoi64 for UTF-8 bytes.
    def self.atoi64(bytes : Bytes) : IntegerParse
      finish = bytes.size
      position = 0
      negative = false
      while position < finish && space?(bytes.unsafe_fetch(position))
        position += 1
      end
      if position < finish
        if bytes.unsafe_fetch(position) == '-'.ord
          negative = true
          position += 1
        elsif bytes.unsafe_fetch(position) == '+'.ord
          position += 1
        end
      end
      start = position
      while position < finish && bytes.unsafe_fetch(position) == '0'.ord
        position += 1
      end
      accumulated = 0_u64
      count = 0
      while position + count < finish && digit?(bytes.unsafe_fetch(position + count))
        accumulated = accumulated &* 10 &+ (bytes.unsafe_fetch(position + count) - 0x30_u8)
        count += 1
      end
      value = if accumulated > LARGEST_INT64.to_u64
                negative ? SMALLEST_INT64 : LARGEST_INT64
              elsif negative
                -(accumulated.to_i64)
              else
                accumulated.to_i64
              end
      code = 0
      if count == 0 && start == position
        code = -1
      elsif position + count < finish
        rest = position + count
        while rest < finish
          unless space?(bytes.unsafe_fetch(rest))
            code = 1
            break
          end
          rest += 1
        end
      end
      return IntegerParse.new(value, code) if count < 19
      comparison = count > 19 ? 1 : compare_to_two_to_the_63(bytes, position)
      return IntegerParse.new(value, code) if comparison < 0
      clamped = negative ? SMALLEST_INT64 : LARGEST_INT64
      return IntegerParse.new(clamped, 2) if comparison > 0
      IntegerParse.new(clamped, negative ? code : 3)
    end

    private def self.compare_to_two_to_the_63(bytes : Bytes, position : Int32) : Int32
      pow63 = "922337203685477580"
      comparison = 0
      index = 0
      while comparison == 0 && index < 18
        comparison = (bytes[position + index].to_i32 - pow63.byte_at(index).to_i32) * 10
        index += 1
      end
      comparison = bytes[position + 18].to_i32 - '8'.ord if comparison == 0
      comparison
    end

    # sqlite3RealToI64: the closest integer, clamped to the Int64 range.
    def self.real_to_i64(real : Float64) : Int64
      return SMALLEST_INT64 if real < -9223372036854774784.0
      return LARGEST_INT64 if real > 9223372036854774784.0
      return 0_i64 if real.nan?
      real.to_i64!
    end

    # sqlite3RealSameAsInt: the real equals the integer and the integer fits
    # in 51 bits (or the real is zero).
    def self.real_same_as_int?(real : Float64, integer : Int64) : Bool
      real == 0.0 || (integer.to_f64.unsafe_as(UInt64) == real.unsafe_as(UInt64) &&
        integer >= -2251799813685248_i64 && integer < 2251799813685248_i64)
    end

    # sqlite3Int64ToText.
    def self.integer_text(value : Int64) : String
      value.to_s
    end

    # A REAL as SQLite renders it when it converts it to text:
    # `sqlite3_str_appendf("%!.15g")` in vdbeMemRenderNum.
    def self.real_text(value : Float64) : String
      format_float(value, FloatFormat::Generic, 15, alternate_form_2: true)
    end

    # The significant digits of a double, from sqlite3FpDecode.
    struct Decoded
      getter sign : Char
      getter digits : String
      # Position of the decimal point relative to the first digit.
      getter decimal_point : Int32
      # 0 for a finite number, 1 for infinity, 2 for NaN.
      getter special : Int32

      def initialize(@sign : Char, @digits : String, @decimal_point : Int32, @special : Int32)
      end
    end

    # sqlite3FpDecode(r, iRound, mxRound).
    def self.fp_decode(real : Float64, round : Int32, max_round : Int32) : Decoded
      sign = '+'
      if real < 0.0
        sign = '-'
        real = -real
      elsif real == 0.0
        return Decoded.new('+', "0", 1, 0)
      end
      bits = real.unsafe_as(UInt64)
      if (bits >> 52) & 0x7ff == 0x7ff
        return Decoded.new(sign, "", 0, bits != 0x7ff0000000000000_u64 ? 2 : 1)
      end
      exponent = 0
      high = real
      low = 0.0
      if high > 9.223372036854774784e+18
        while high > 9.223372036854774784e+118
          exponent += 100
          high, low = dekker_multiply(high, low, 1.0e-100, -1.99918998026028836196e-117)
        end
        while high > 9.223372036854774784e+28
          exponent += 10
          high, low = dekker_multiply(high, low, 1.0e-10, -3.6432197315497741579e-27)
        end
        while high > 9.223372036854774784e+18
          exponent += 1
          high, low = dekker_multiply(high, low, 1.0e-01, -5.5511151231257827021e-18)
        end
      else
        while high < 9.223372036854774784e-83
          exponent -= 100
          high, low = dekker_multiply(high, low, 1.0e+100, -1.5902891109759918046e+83)
        end
        while high < 9.223372036854774784e+07
          exponent -= 10
          high, low = dekker_multiply(high, low, 1.0e+10, 0.0)
        end
        while high < 9.22337203685477478e+17
          exponent -= 1
          high, low = dekker_multiply(high, low, 1.0e+01, 0.0)
        end
      end
      whole = low < 0.0 ? high.to_u64! &- (-low).to_u64! : high.to_u64! &+ low.to_u64!
      digits = whole.to_s.to_slice.dup
      count = digits.size
      decimal_point = count + exponent
      leading_carry = false
      if round <= 0
        round = decimal_point - round
        if round == 0 && digits[0] >= '5'.ord
          round = 1
          leading_carry = true
        end
      end
      if leading_carry
        # The digit string becomes "0" followed by the digits, rounded to one.
        digits = Bytes.new(count + 1) { |index| index == 0 ? '0'.ord.to_u8 : digits[index - 1] }
        count += 1
        decimal_point += 1
      end
      if round > 0 && (round < count || count > max_round)
        round = max_round if round > max_round
        carry_out = false
        if digits[round] >= '5'.ord
          position = round - 1
          loop do
            digits[position] += 1
            break if digits[position] <= '9'.ord
            digits[position] = '0'.ord.to_u8
            if position == 0
              carry_out = true
              break
            end
            position -= 1
          end
        end
        count = round
        if carry_out
          digits = Bytes.new(count + 1) { |index| index == 0 ? '1'.ord.to_u8 : digits[index - 1] }
          count += 1
          decimal_point += 1
        end
      end
      while count > 1 && digits[count - 1] == '0'.ord
        count -= 1
      end
      Decoded.new(sign, String.new(digits[0, count]), decimal_point, 0)
    end

    enum FloatFormat
      Fixed       # %f
      Exponential # %e
      Generic     # %g
    end

    # printf's %f, %e and %g conversions of SQLite's printf.c with
    # *precision* and the `!` flag, without width or other flags.
    def self.format_float(value : Float64, format : FloatFormat, precision : Int32, alternate_form_2 : Bool) : String
      round = case format
              in .fixed? then -precision
              in .generic?
                precision = 1 if precision == 0
                precision
              in .exponential? then precision + 1
              end
      decoded = fp_decode(value, round, alternate_form_2 ? 26 : 16)
      return "NaN" if decoded.special == 2
      return decoded.sign == '-' ? "-Inf" : "Inf" if decoded.special == 1
      exponent = decoded.decimal_point - 1
      use_exponent = format.exponential?
      if format.generic?
        precision -= 1
        trim_zeros = true
        if exponent < -4 || exponent > precision
          use_exponent = true
        else
          precision -= exponent
        end
      else
        trim_zeros = alternate_form_2
      end
      digits = decoded.digits
      e2 = use_exponent ? 0 : decoded.decimal_point - 1
      with_point = precision > 0 || alternate_form_2
      String.build do |io|
        io << '-' if decoded.sign == '-'
        body = String::Builder.new
        index = 0
        if e2 < 0
          body << '0'
        else
          while e2 >= 0
            if index < digits.bytesize
              body << digits.byte_at(index).unsafe_chr
              index += 1
            else
              body << '0'
            end
            e2 -= 1
          end
        end
        body << '.' if with_point
        e2 += 1
        while e2 < 0 && precision > 0
          body << '0'
          precision -= 1
          e2 += 1
        end
        while precision > 0
          if index < digits.bytesize
            body << digits.byte_at(index).unsafe_chr
            index += 1
          else
            body << '0'
          end
          precision -= 1
        end
        text = body.to_s
        if trim_zeros && with_point
          text = text.rstrip('0')
          text = alternate_form_2 ? "#{text}0" : text.rchop if text.ends_with?('.')
        end
        io << text
        if use_exponent
          written = decoded.decimal_point - 1
          io << 'e' << (written < 0 ? '-' : '+')
          written = written.abs
          if written >= 100
            io << written // 100
            written %= 100
          end
          io << written // 10 << written % 10
        end
      end
    end
  end
end
