module Grant::Mica
  struct Decimal128
    private MAX_MAGNITUDE = MAX_COEFFICIENT.to_u128!

    # Returns the exact sum, at the larger of the two scales. Raises
    # `OverflowError` when the sum needs more than 38 digits.
    #
    # ```
    # Grant::Mica::Decimal128.parse("0.1") + Grant::Mica::Decimal128.parse("0.20") # => 0.30
    # ```
    def +(other : Decimal128) : Decimal128
      add(other.coefficient, other.scale)
    end

    # Returns the exact difference, at the larger of the two scales. Raises
    # `OverflowError` when it needs more than 38 digits.
    def -(other : Decimal128) : Decimal128
      add(-other.coefficient, other.scale)
    end

    private def add(other_coefficient : Int128, other_scale : Int32) : Decimal128
      if @scale == other_scale
        return Decimal128.from_sum(@coefficient, other_coefficient, @scale)
      end
      if @scale < other_scale
        Decimal128.add_scaled(@coefficient, other_scale &- @scale, other_coefficient, other_scale)
      else
        Decimal128.add_scaled(other_coefficient, @scale &- other_scale, @coefficient, @scale)
      end
    end

    # Returns `a + b` at *scale*, both already at that scale.
    protected def self.from_sum(a : Int128, b : Int128, scale : Int32) : Decimal128
      # Both magnitudes are below 10**38, so the sum is below 2**128 and
      # only wraps when both have the same sign.
      sum = a &+ b
      if sum > MAX_COEFFICIENT || sum < -MAX_COEFFICIENT || ((a < 0) == (b < 0) && (sum < 0) != (a < 0))
        raise OverflowError.new("the sum needs more than #{MAX_DIGITS} digits")
      end
      new(sum, scale, checked: true)
    end

    # Returns `low * 10**shift + high` at *scale*.
    protected def self.add_scaled(low : Int128, shift : Int32, high : Int128, scale : Int32) : Decimal128
      magnitude = low.abs.to_u128!
      if magnitude < POW10[MAX_DIGITS &- shift]
        return from_sum(low &* POW10[shift].to_i128!, high, scale)
      end
      # The scaled operand has more than 38 digits; the sum fits only when
      # the other operand nearly cancels it.
      scaled = Wide.multiply(magnitude, POW10[shift])
      other = Wide.new(high.abs.to_u128!)
      if (low < 0) == (high < 0)
        raise OverflowError.new("the sum needs more than #{MAX_DIGITS} digits")
      end
      if scaled > other
        difference = scaled - other
        negative = low < 0
      else
        difference = other - scaled
        negative = high < 0
      end
      unless difference.fits_128? && difference.low <= MAX_MAGNITUDE
        raise OverflowError.new("the sum needs more than #{MAX_DIGITS} digits")
      end
      value = difference.low.to_i128!
      new(negative ? -value : value, scale, checked: true)
    end

    # Returns the exact product, at the sum of the two scales. Raises
    # `OverflowError` when the product needs more than 38 digits or the
    # scale passes 38.
    #
    # ```
    # Grant::Mica::Decimal128.parse("19.99") * Grant::Mica::Decimal128.parse("0.07") # => 1.3993
    # ```
    def *(other : Decimal128) : Decimal128
      scale = @scale &+ other.scale
      if scale > MAX_SCALE
        raise OverflowError.new("the product's scale #{scale} is above #{MAX_SCALE}")
      end
      a = @coefficient.abs.to_u128!
      b = other.coefficient.abs.to_u128!
      negative = (@coefficient < 0) != (other.coefficient < 0)
      if (a | b) >> 64 == 0
        product = a &* b
      else
        wide = Wide.multiply(a, b)
        unless wide.fits_128?
          raise OverflowError.new("the product needs more than #{MAX_DIGITS} digits")
        end
        product = wide.low
      end
      if product > MAX_MAGNITUDE
        raise OverflowError.new("the product needs more than #{MAX_DIGITS} digits")
      end
      value = product.to_i128!
      Decimal128.new(negative ? -value : value, scale, checked: true)
    end

    # Returns this value divided by *other*, rounded to *scale* digits after
    # the point with *rounding*. Raises `DivisionByZeroError` for a zero
    # divisor, `OverflowError` when the rounded quotient needs more than 38
    # digits, and `InexactError` for `RoundingMode::Unnecessary` when the
    # quotient does not end within *scale*.
    #
    # ```
    # one = Grant::Mica::Decimal128.new(1)
    # one.divide(Grant::Mica::Decimal128.new(3), 2, :ties_away)   # => 0.33
    # one.divide(Grant::Mica::Decimal128.new(8), 3, :unnecessary) # => 0.125
    # ```
    def divide(other : Decimal128, scale : Int32, rounding : RoundingMode) : Decimal128
      Decimal128.check_scale(scale)
      raise DivisionByZeroError.new("division of #{self} by zero") if other.zero?
      return Decimal128.new(0_i128, scale, checked: true) if zero?

      negative = (@coefficient < 0) != (other.coefficient < 0)
      a = @coefficient.abs.to_u128!
      b = other.coefficient.abs.to_u128!
      # self / other = (a / 10**s1) / (b / 10**s2); at the result scale the
      # coefficient is a * 10**(s2 + scale - s1) / b.
      exponent = other.scale &+ scale &- @scale
      if exponent >= 0
        excess = Decimal128.digit_count(a) &+ exponent &- Decimal128.digit_count(b) &- MAX_DIGITS
        raise OverflowError.new("the quotient needs more than #{MAX_DIGITS} digits") if excess > 0
        dividend = Decimal128.scale_up(a, exponent)
        divisor = Wide.new(b)
        # At the boundary the quotient may reach 10**38: compare exactly.
        if excess == 0 && dividend >= Wide.multiply(b, POW10[MAX_DIGITS])
          raise OverflowError.new("the quotient needs more than #{MAX_DIGITS} digits")
        end
      else
        dividend = Wide.new(a)
        divisor = Wide.multiply(b, POW10[-exponent])
      end
      quotient, remainder = Wide.divmod(dividend, divisor)
      quotient = Decimal128.rounded(quotient, remainder, divisor, negative, rounding)
      Decimal128.signed(quotient, negative, scale)
    end

    # Returns the value rounded to *scale* digits after the point with
    # *mode*. A value whose scale is already *scale* or less comes back
    # unchanged; use `rescale` to pad it.
    #
    # ```
    # Grant::Mica::Decimal128.parse("2.345").round(2, :ties_even)  # => 2.34
    # Grant::Mica::Decimal128.parse("-2.345").round(2, :ties_away) # => -2.35
    # Grant::Mica::Decimal128.parse("2.3").round(2, :floor)        # => 2.3
    # ```
    def round(scale : Int32, mode : RoundingMode) : Decimal128
      Decimal128.check_scale(scale)
      return self if scale >= @scale
      shrink(scale, mode)
    end

    # Returns the value at exactly *scale* digits after the point. Raising
    # the scale is exact (and raises `OverflowError` past 38 digits);
    # lowering it rounds with *mode*, which by default raises `InexactError`
    # instead of dropping a nonzero digit.
    #
    # ```
    # Grant::Mica::Decimal128.parse("12.3").rescale(2)              # => 12.30
    # Grant::Mica::Decimal128.parse("12.30").rescale(1)             # => 12.3
    # Grant::Mica::Decimal128.parse("12.35").rescale(1, :ties_even) # => 12.4
    # ```
    def rescale(scale : Int32, mode : RoundingMode = :unnecessary) : Decimal128
      Decimal128.check_scale(scale)
      return self if scale == @scale
      return shrink(scale, mode) if scale < @scale

      shift = scale &- @scale
      magnitude = @coefficient.abs.to_u128!
      unless magnitude < POW10[MAX_DIGITS &- shift]
        raise OverflowError.new("#{self} at scale #{scale} needs more than #{MAX_DIGITS} digits")
      end
      Decimal128.new(@coefficient &* POW10[shift].to_i128!, scale, checked: true)
    end

    private def shrink(scale : Int32, mode : RoundingMode) : Decimal128
      shift = @scale &- scale
      negative = @coefficient < 0
      magnitude = @coefficient.abs.to_u128!
      divisor = POW10[shift]
      if magnitude >> 64 == 0 && shift <= 19
        small = magnitude.to_u64!
        small_divisor = divisor.to_u64!
        quotient = (small // small_divisor).to_u128!
        remainder = Wide.new((small % small_divisor).to_u128!)
      else
        quotient = magnitude // divisor
        remainder = Wide.new(magnitude % divisor)
      end
      quotient = Decimal128.rounded(quotient, remainder, Wide.new(divisor), negative, mode)
      Decimal128.signed(quotient, negative, scale)
    end

    # Returns *quotient* moved one unit away from zero when *mode* asks for
    # it, given the *remainder* left over a *divisor*.
    protected def self.rounded(quotient : UInt128, remainder : Wide, divisor : Wide, negative : Bool, mode : RoundingMode) : UInt128
      return quotient if remainder.zero?
      up = case mode
           in .truncate?  then false
           in .floor?     then negative
           in .ceiling?   then !negative
           in .ties_away? then remainder >= divisor - remainder
           in .ties_even?
             half = remainder <=> (divisor - remainder)
             half > 0 || (half == 0 && quotient.odd?)
           in .unnecessary? then raise InexactError.new("rounding would drop a nonzero digit")
           end
      up ? quotient &+ 1 : quotient
    end

    protected def self.signed(magnitude : UInt128, negative : Bool, scale : Int32) : Decimal128
      if magnitude > MAX_MAGNITUDE
        raise OverflowError.new("the result needs more than #{MAX_DIGITS} digits")
      end
      value = magnitude.to_i128!
      new(negative ? -value : value, scale, checked: true)
    end

    # Returns *value* * 10**exponent; the caller guarantees it fits 256 bits.
    protected def self.scale_up(value : UInt128, exponent : Int32) : Wide
      if exponent <= MAX_DIGITS
        Wide.multiply(value, POW10[exponent])
      else
        Wide.multiply(value, POW10[MAX_DIGITS]).multiply(POW10[exponent &- MAX_DIGITS])
      end
    end

    # Compares by value: `12.30 <=> 12.3` is 0.
    def <=>(other : Decimal128) : Int32
      return @coefficient <=> other.coefficient if @scale == other.scale

      sign = self.sign
      other_sign = other.sign
      return sign <=> other_sign if sign != other_sign || sign == 0

      a = @coefficient.abs.to_u128!
      b = other.coefficient.abs.to_u128!
      magnitude = if @scale < other.scale
                    Decimal128.compare_scaled(a, other.scale &- @scale, b)
                  else
                    -Decimal128.compare_scaled(b, @scale &- other.scale, a)
                  end
      sign < 0 ? -magnitude : magnitude
    end

    # Compares `low * 10**shift` with *high*.
    protected def self.compare_scaled(low : UInt128, shift : Int32, high : UInt128) : Int32
      if low < POW10[MAX_DIGITS &- shift]
        low &* POW10[shift] <=> high
      else
        # More than 38 digits once scaled, so larger than any coefficient.
        1
      end
    end

    # Returns true when both have the same value, at any scales.
    def ==(other : Decimal128) : Bool
      return @coefficient == other.coefficient if @scale == other.scale
      (self <=> other) == 0
    end

    # Hashes the value without trailing fraction zeros, so equal values at
    # different scales hash equally.
    def hash(hasher)
      coefficient, scale = normalized
      hasher = coefficient.hash(hasher)
      scale.hash(hasher)
    end

    # Returns the coefficient and scale with trailing fraction zeros removed.
    # :nodoc:
    def normalized : {Int128, Int32}
      coefficient = @coefficient
      scale = @scale
      return {0_i128, 0} if coefficient == 0
      if Int64::MIN < coefficient <= Int64::MAX
        small = coefficient.to_i64!
        while scale > 0 && small % 10 == 0
          small = small.tdiv(10)
          scale &-= 1
        end
        return {small.to_i128!, scale}
      end
      while scale > 0 && coefficient % 10 == 0
        coefficient = coefficient.tdiv(10)
        scale &-= 1
      end
      {coefficient, scale}
    end
  end
end
