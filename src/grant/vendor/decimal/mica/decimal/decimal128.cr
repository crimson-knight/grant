module Grant::Mica
  # An exact decimal number of up to 38 significant digits: an `Int128`
  # coefficient and a scale from 0 to 38, worth `coefficient / 10**scale`.
  #
  # The scale is part of the value's form, not of its worth: `12.30` has
  # scale 2 and prints with its trailing zero, yet equals `12.3` and hashes
  # the same. `+` and `-` give the larger scale of the two operands and `*`
  # the sum of the scales; each is exact or raises `OverflowError`.
  # `divide`, `round` and `rescale` take the result scale and a
  # `RoundingMode`.
  #
  # Every operation but `parse` and `to_s` works on the stack (128-bit
  # integers and a 256-bit intermediate), so arithmetic allocates nothing.
  #
  # ```
  # a = Grant::Mica::Decimal128.parse("12.30")
  # a.scale                                                                # => 2
  # a == Grant::Mica::Decimal128.parse("12.3")                                    # => true
  # a * Grant::Mica::Decimal128.new(3)                                            # => 36.90
  # Grant::Mica::Decimal128.new(1).divide(Grant::Mica::Decimal128.new(3), 4, :ties_even) # => 0.3333
  # ```
  struct Decimal128
    include Comparable(Decimal128)

    # The most digits a coefficient holds.
    MAX_DIGITS = 38

    # The largest scale (digits after the point).
    MAX_SCALE = 38

    # The largest coefficient magnitude, 10**38 - 1.
    MAX_COEFFICIENT = 99999999999999999999999999999999999999_i128

    # Powers of ten from 10**0 to 10**38.
    # :nodoc:
    POW10 = StaticArray[
      1_u128,
      10_u128,
      100_u128,
      1000_u128,
      10000_u128,
      100000_u128,
      1000000_u128,
      10000000_u128,
      100000000_u128,
      1000000000_u128,
      10000000000_u128,
      100000000000_u128,
      1000000000000_u128,
      10000000000000_u128,
      100000000000000_u128,
      1000000000000000_u128,
      10000000000000000_u128,
      100000000000000000_u128,
      1000000000000000000_u128,
      10000000000000000000_u128,
      100000000000000000000_u128,
      1000000000000000000000_u128,
      10000000000000000000000_u128,
      100000000000000000000000_u128,
      1000000000000000000000000_u128,
      10000000000000000000000000_u128,
      100000000000000000000000000_u128,
      1000000000000000000000000000_u128,
      10000000000000000000000000000_u128,
      100000000000000000000000000000_u128,
      1000000000000000000000000000000_u128,
      10000000000000000000000000000000_u128,
      100000000000000000000000000000000_u128,
      1000000000000000000000000000000000_u128,
      10000000000000000000000000000000000_u128,
      100000000000000000000000000000000000_u128,
      1000000000000000000000000000000000000_u128,
      10000000000000000000000000000000000000_u128,
      100000000000000000000000000000000000000_u128,
    ]

    # The coefficient: the value's digits as an integer, sign included.
    getter coefficient : Int128

    # The number of digits after the decimal point, 0 to 38.
    getter scale : Int32

    # Creates `coefficient / 10**scale`. Raises `OverflowError` when the
    # coefficient has more than 38 digits and `ArgumentError` when the
    # scale is outside 0..38.
    #
    # ```
    # Grant::Mica::Decimal128.new(1230, 2) # => 12.30
    # Grant::Mica::Decimal128.new(-5)      # => -5
    # ```
    def initialize(coefficient : Int, scale : Int32 = 0)
      Decimal128.check_scale(scale)
      unless coefficient <= MAX_COEFFICIENT && coefficient >= -MAX_COEFFICIENT
        raise OverflowError.new("#{coefficient} has more than #{MAX_DIGITS} digits")
      end
      @coefficient = coefficient.to_i128!
      @scale = scale
    end

    # Creates a value whose parts the caller has already checked.
    protected def initialize(@coefficient : Int128, @scale : Int32, *, checked : Bool)
    end

    # Returns zero at *scale*.
    def self.zero(scale : Int32 = 0) : self
      check_scale(scale)
      new(0_i128, scale, checked: true)
    end

    # :nodoc:
    def self.check_scale(scale : Int32) : Nil
      unless 0 <= scale <= MAX_SCALE
        raise ArgumentError.new("Decimal128 scale must be within 0..#{MAX_SCALE}, not #{scale}")
      end
    end

    # Returns true when the value is zero, at any scale.
    def zero? : Bool
      @coefficient == 0
    end

    # Returns true when the value is below zero.
    def negative? : Bool
      @coefficient < 0
    end

    # Returns true when the value is above zero.
    def positive? : Bool
      @coefficient > 0
    end

    # Returns -1, 0 or 1 for a negative, zero or positive value.
    def sign : Int32
      @coefficient < 0 ? -1 : (@coefficient == 0 ? 0 : 1)
    end

    # Returns the value with its sign flipped, at the same scale.
    def - : Decimal128
      Decimal128.new(-@coefficient, @scale, checked: true)
    end

    # Returns the magnitude, at the same scale.
    def abs : Decimal128
      Decimal128.new(@coefficient.abs, @scale, checked: true)
    end

    # Returns the number of digits in the coefficient (1 for zero).
    #
    # ```
    # Grant::Mica::Decimal128.parse("12.30").precision # => 4
    # ```
    def precision : Int32
      Decimal128.digit_count(@coefficient.abs.to_u128!)
    end

    # Returns the integer part, truncated toward zero. Raises
    # `OverflowError` when it does not fit an `Int64`.
    def to_i64 : Int64
      whole = @scale == 0 ? @coefficient : @coefficient.tdiv(POW10[@scale].to_i128!)
      unless Int64::MIN <= whole <= Int64::MAX
        raise OverflowError.new("#{self} does not fit Int64")
      end
      whole.to_i64!
    end

    # Returns the nearest `Float64` (correctly rounded).
    def to_f64 : Float64
      magnitude = @coefficient.abs
      # Both operands are exact in a Float64, so the quotient rounds once.
      if magnitude < (1_i128 << 53) && @scale <= 22
        quotient = magnitude.to_f64! / FLOAT_POW10[@scale]
        return @coefficient < 0 ? -quotient : quotient
      end
      buffer = uninitialized StaticArray(UInt8, 48)
      length = write_plain(buffer.to_unsafe)
      buffer[length] = 0_u8
      LibC.strtod(buffer.to_unsafe.as(LibC::Char*), nil)
    end

    # Powers of ten that a Float64 holds exactly.
    # :nodoc:
    FLOAT_POW10 = StaticArray[
      1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
      1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
    ]

    # Returns the number of decimal digits of *value* (1 for zero).
    # :nodoc:
    def self.digit_count(value : UInt128) : Int32
      return 1 if value < 10
      bits = 128 - value.leading_zeros_count
      # 1233 / 4096 is just over log10(2); the guess is exact or one low.
      guess = (bits &* 1233) >> 12
      value >= POW10[guess] ? guess &+ 1 : guess
    end
  end
end
