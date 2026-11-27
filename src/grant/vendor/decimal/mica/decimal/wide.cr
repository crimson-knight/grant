module Grant::Mica
  struct Decimal128
    # An unsigned 256-bit integer as two `UInt128` halves, for the products
    # and dividends that do not fit 128 bits. It lives on the stack and
    # carries only what `Decimal128` needs: the full 128 x 128 product,
    # comparison, subtraction, shifts and long division with a quotient
    # below 2**128.
    # :nodoc:
    struct Wide
      include Comparable(Wide)

      LOW_64 = 0xFFFF_FFFF_FFFF_FFFF_u128

      getter high : UInt128
      getter low : UInt128

      def initialize(@high : UInt128, @low : UInt128)
      end

      def self.new(low : UInt128) : Wide
        new(0_u128, low)
      end

      # Returns the exact product of *a* and *b*.
      @[AlwaysInline]
      def self.multiply(a : UInt128, b : UInt128) : Wide
        a_high = a >> 64
        b_high = b >> 64
        if a_high == 0 && b_high == 0
          return new(0_u128, a &* b)
        end
        a_low = a & LOW_64
        b_low = b & LOW_64
        low_low = a_low &* b_low
        low_high = a_low &* b_high
        high_low = a_high &* b_low
        high_high = a_high &* b_high
        middle = (low_low >> 64) &+ (low_high & LOW_64) &+ (high_low & LOW_64)
        low = (low_low & LOW_64) | (middle << 64)
        high = high_high &+ (low_high >> 64) &+ (high_low >> 64) &+ (middle >> 64)
        new(high, low)
      end

      # Returns this value times *factor*; the caller guarantees the
      # product is below 2**256.
      def multiply(factor : UInt128) : Wide
        low_product = Wide.multiply(@low, factor)
        high_product = @high &* factor
        Wide.new(low_product.high &+ high_product, low_product.low)
      end

      def <=>(other : Wide) : Int32
        if @high != other.high
          @high < other.high ? -1 : 1
        elsif @low != other.low
          @low < other.low ? -1 : 1
        else
          0
        end
      end

      # Returns this value minus *other*; the caller guarantees *other* is
      # not larger.
      def -(other : Wide) : Wide
        borrow = @low < other.low ? 1_u128 : 0_u128
        Wide.new(@high &- other.high &- borrow, @low &- other.low)
      end

      def <<(count : Int32) : Wide
        return self if count == 0
        return Wide.new(@low << (count - 128), 0_u128) if count >= 128
        Wide.new((@high << count) | (@low >> (128 - count)), @low << count)
      end

      def >>(count : Int32) : Wide
        return self if count == 0
        return Wide.new(0_u128, @high >> (count - 128)) if count >= 128
        Wide.new(@high >> count, (@low >> count) | (@high << (128 - count)))
      end

      def bit_length : Int32
        if @high != 0
          256 - @high.leading_zeros_count.to_i32
        else
          128 - @low.leading_zeros_count.to_i32
        end
      end

      def zero? : Bool
        @high == 0 && @low == 0
      end

      def fits_128? : Bool
        @high == 0
      end

      # Returns the quotient and remainder of *dividend* / *divisor*. The
      # caller guarantees the divisor is not zero and the quotient is
      # below 2**128.
      def self.divmod(dividend : Wide, divisor : Wide) : {UInt128, Wide}
        if dividend.high == 0 && divisor.high == 0
          numerator = dividend.low
          denominator = divisor.low
          return {numerator // denominator, Wide.new(numerator % denominator)}
        end
        return {0_u128, dividend} if dividend < divisor

        shift = dividend.bit_length - divisor.bit_length
        divisor = divisor << shift
        remainder = dividend
        quotient = 0_u128
        (shift + 1).times do
          quotient <<= 1
          if remainder >= divisor
            remainder = remainder - divisor
            quotient |= 1
          end
          divisor = divisor >> 1
        end
        {quotient, remainder}
      end
    end
  end
end
