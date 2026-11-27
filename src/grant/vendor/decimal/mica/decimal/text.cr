module Grant::Mica
  struct Decimal128
    # Largest exponent magnitude read exactly; larger ones saturate, which
    # changes no outcome (the value is zero, or it overflows).
    private EXPONENT_LIMIT = 1_000_000_i64

    # Parses the decimal number in *text*: an optional sign, digits, an
    # optional `.` with fraction digits, and an optional exponent (`e` or
    # `E`, an optional sign, digits). This covers the text forms of
    # PostgreSQL `numeric`, MySQL `DECIMAL`, JSON numbers and Crystal's
    # `BigDecimal#to_s`.
    #
    # The fraction's trailing zeros are kept as scale (`"12.30"` has scale
    # 2), and an exponent moves the point (`"1.5e-3"` is 0.0015, `"1.2e3"`
    # is 1200). Raises `ParseError` for anything else (including empty
    # text, spaces, `NaN` and `Infinity`) and `OverflowError` when the
    # exact value needs more than 38 digits or a scale above 38. Trailing
    # zeros give way first: `"1.000e-38"` parses as 0.00…01, coefficient 1 at scale 38.
    #
    # ```
    # Grant::Mica::Decimal128.parse("-0.50")      # => -0.50
    # Grant::Mica::Decimal128.parse("1.0e-6")     # => 0.0000010
    # Grant::Mica::Decimal128.parse("1.2345e+19") # => 12345000000000000000
    # ```
    def self.parse(text : String) : Decimal128
      result = parse_text(text)
      return result if result.is_a?(Decimal128)
      if result.overflow?
        raise OverflowError.new("#{text.inspect} needs more than #{MAX_DIGITS} digits or a scale above #{MAX_SCALE}")
      end
      raise ParseError.new("#{text.inspect} is not a decimal number")
    end

    # Like `parse`, but returns nil instead of raising.
    def self.parse?(text : String) : Decimal128?
      result = parse_text(text)
      result.is_a?(Decimal128) ? result : nil
    end

    private enum ParseFailure
      Malformed
      Overflow
    end

    private def self.parse_text(text : String) : Decimal128 | ParseFailure
      bytes = text.to_unsafe
      size = text.bytesize
      index = 0
      negative = false
      if index < size && (bytes[index] == '-'.ord || bytes[index] == '+'.ord)
        negative = bytes[index] == '-'.ord
        index &+= 1
      end

      coefficient = 0_u128
      significant_digits = 0 # digits of the coefficient so far
      pending_zeros = 0      # zeros read after the last nonzero digit
      integer_digits = 0
      fraction_digits = 0

      while (digit = digit_at(bytes, index, size)) < 10
        coefficient, significant_digits, pending_zeros = take_digit(coefficient, significant_digits, pending_zeros, digit)
        return ParseFailure::Overflow if significant_digits > MAX_DIGITS
        integer_digits &+= 1
        index &+= 1
      end
      return ParseFailure::Malformed if integer_digits == 0

      if index < size && bytes[index] == '.'.ord
        index &+= 1
        while (digit = digit_at(bytes, index, size)) < 10
          coefficient, significant_digits, pending_zeros = take_digit(coefficient, significant_digits, pending_zeros, digit)
          return ParseFailure::Overflow if significant_digits > MAX_DIGITS
          fraction_digits &+= 1
          index &+= 1
        end
        return ParseFailure::Malformed if fraction_digits == 0
      end

      exponent = 0_i64
      if index < size && (bytes[index] == 'e'.ord || bytes[index] == 'E'.ord)
        index &+= 1
        exponent_negative = false
        if index < size && (bytes[index] == '-'.ord || bytes[index] == '+'.ord)
          exponent_negative = bytes[index] == '-'.ord
          index &+= 1
        end
        exponent_digits = 0
        while (digit = digit_at(bytes, index, size)) < 10
          exponent = exponent &* 10 &+ digit if exponent < EXPONENT_LIMIT
          exponent_digits &+= 1
          index &+= 1
        end
        return ParseFailure::Malformed if exponent_digits == 0
        exponent = -exponent if exponent_negative
      end
      return ParseFailure::Malformed if index != size

      # The written form asks for this scale.
      natural_scale = fraction_digits.to_i64 &- exponent
      if coefficient == 0
        return Decimal128.new(0_i128, natural_scale.clamp(0_i64, MAX_SCALE.to_i64).to_i32!, checked: true)
      end

      # The value is coefficient * 10**value_exponent, with the trailing
      # zeros of the digits held back in pending_zeros.
      value_exponent = pending_zeros.to_i64 &- natural_scale
      lowest_scale = Math.max(0_i64, -value_exponent)
      highest_scale = MAX_DIGITS.to_i64 &- significant_digits &- value_exponent
      scale = Math.min(natural_scale.clamp(0_i64, MAX_SCALE.to_i64), highest_scale)
      return ParseFailure::Overflow if scale < lowest_scale

      coefficient = coefficient &* POW10[(value_exponent &+ scale).to_i32!]
      value = coefficient.to_i128!
      Decimal128.new(negative ? -value : value, scale.to_i32!, checked: true)
    end

    # Returns the digit at *index*, or 255 past the end or for a non-digit.
    @[AlwaysInline]
    private def self.digit_at(bytes : UInt8*, index : Int32, size : Int32) : UInt8
      index < size ? bytes[index] &- 48 : 255_u8
    end

    # Adds one digit, keeping trailing zeros out of the coefficient until a
    # nonzero digit follows them.
    @[AlwaysInline]
    private def self.take_digit(coefficient : UInt128, significant_digits : Int32, pending_zeros : Int32, digit : UInt8) : {UInt128, Int32, Int32}
      if digit == 0
        return {coefficient, significant_digits, pending_zeros} if significant_digits == 0
        return {coefficient, significant_digits, pending_zeros &+ 1}
      end
      significant_digits &+= pending_zeros &+ 1
      if significant_digits <= MAX_DIGITS
        coefficient = coefficient &* POW10[pending_zeros &+ 1] &+ digit
      end
      {coefficient, significant_digits, 0}
    end

    # Returns the plain form: digits, a point when the scale is above zero,
    # and every digit of the scale (`12.30`, `-0.05`, `0.0000`). Never an
    # exponent.
    def to_s : String
      buffer = uninitialized StaticArray(UInt8, 48)
      length = write_plain(buffer.to_unsafe)
      String.new(buffer.to_unsafe, length)
    end

    # Writes the plain form to *io*.
    def to_s(io : IO) : Nil
      buffer = uninitialized StaticArray(UInt8, 48)
      length = write_plain(buffer.to_unsafe)
      io.write_string(buffer.to_slice[0, length])
    end

    # Writes the plain form, as `to_s` does.
    def inspect(io : IO) : Nil
      to_s(io)
    end

    # Writes the plain form at *output* (room for 41 bytes) and returns its
    # length.
    protected def write_plain(output : UInt8*) : Int32
      digits = uninitialized StaticArray(UInt8, 40)
      count = Decimal128.write_digits(@coefficient.abs.to_u128!, digits.to_unsafe + 40)
      first = digits.to_unsafe + (40 &- count)
      length = 0
      if @coefficient < 0
        output[0] = '-'.ord.to_u8
        length = 1
      end
      if @scale == 0
        (output + length).copy_from(first, count)
        return length &+ count
      end
      if count > @scale
        whole = count &- @scale
        (output + length).copy_from(first, whole)
        length &+= whole
        output[length] = '.'.ord.to_u8
        (output + (length &+ 1)).copy_from(first + whole, @scale)
        return length &+ 1 &+ @scale
      end
      output[length] = '0'.ord.to_u8
      output[length &+ 1] = '.'.ord.to_u8
      length &+= 2
      zeros = @scale &- count
      zeros.times { |offset| output[length &+ offset] = '0'.ord.to_u8 }
      length &+= zeros
      (output + length).copy_from(first, count)
      length &+ count
    end

    private TEN_TO_19 = 10_000_000_000_000_000_000_u128

    # Writes the digits of *value* backward, ending just before *finish*,
    # and returns how many were written.
    protected def self.write_digits(value : UInt128, finish : UInt8*) : Int32
      if value >> 64 == 0
        return write_digits_64(value.to_u64!, finish, 0)
      end
      # Below 10**38, so the high part is below 10**19 and fits a UInt64.
      high = value // TEN_TO_19
      low = (value &- high &* TEN_TO_19).to_u64!
      write_digits_64(low, finish, 19)
      19 &+ write_digits_64(high.to_u64!, finish - 19, 0)
    end

    # Writes *value* backward, padded with zeros to *width* digits.
    private def self.write_digits_64(value : UInt64, finish : UInt8*, width : Int32) : Int32
      count = 0
      loop do
        count &+= 1
        quotient = value // 10
        finish[-count] = (value &- quotient &* 10).to_u8! &+ 48
        value = quotient
        break if value == 0 && count >= width
      end
      count
    end
  end
end
