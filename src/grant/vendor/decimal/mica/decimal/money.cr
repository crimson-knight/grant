module Grant::Mica
  # An amount of one currency: a `Decimal128` and a `Currency`.
  #
  # Arithmetic is exact and only between equal currencies; `round` goes to
  # the currency's minor unit with an explicit mode; `allocate` and `split`
  # divide an amount into parts that add up to it exactly, never losing or
  # inventing a minor unit. `to_s` is plain (`"12.30 USD"`); locale
  # formatting belongs to the presentation layer.
  #
  # ```
  # total = Grant::Mica::Money.new("100.00", "USD")
  # total.split(3).map(&.to_s)               # => ["33.34 USD", "33.33 USD", "33.33 USD"]
  # total.allocate([70, 20, 10]).map(&.to_s) # => ["70.00 USD", "20.00 USD", "10.00 USD"]
  # (total * 3).to_s                         # => "300.00 USD"
  # ```
  struct Money
    # Base class of every error `Money` raises itself. Amount and currency
    # errors come from `Decimal128` and `Currency`.
    class Error < Exception
    end

    # Raised by `+` and `-` for two different currencies.
    class CurrencyMismatchError < Error
    end

    # The amount, at the scale it was given or computed at.
    getter amount : Decimal128

    # The currency.
    getter currency : Currency

    # Creates an amount of *currency*. A String amount is parsed with
    # `Decimal128.parse` and a String currency looked up with
    # `Currency.find`. The amount keeps its scale; `round` brings it to
    # the currency's minor unit.
    def initialize(amount : Decimal128 | String | Int, currency : Currency | String)
      @amount = case amount
                when Decimal128 then amount
                when String     then Decimal128.parse(amount)
                else                 Decimal128.new(amount)
                end
      @currency = currency.is_a?(Currency) ? currency : Currency.find(currency)
    end

    # Returns the exact sum. Raises `CurrencyMismatchError` for another
    # currency.
    def +(other : Money) : Money
      Money.new(@amount + same_currency(other, "add").amount, @currency)
    end

    # Returns the exact difference. Raises `CurrencyMismatchError` for
    # another currency.
    def -(other : Money) : Money
      Money.new(@amount - same_currency(other, "subtract").amount, @currency)
    end

    # Returns the amount with its sign flipped.
    def - : Money
      Money.new(-@amount, @currency)
    end

    # Returns the exact product, at the amount's scale plus the factor's.
    #
    # ```
    # (Grant::Mica::Money.new("19.99", "USD") * Grant::Mica::Decimal128.parse("1.07")).to_s # => "21.3893 USD"
    # ```
    def *(factor : Decimal128 | Int) : Money
      multiplier = factor.is_a?(Decimal128) ? factor : Decimal128.new(factor)
      Money.new(@amount * multiplier, @currency)
    end

    # Returns the amount rounded with *mode* to the currency's minor units
    # (and padded to them: 12.3 USD becomes 12.30 USD). Raises
    # `Currency::NoMinorUnitsError` for a currency without minor units.
    def round(mode : Decimal128::RoundingMode) : Money
      Money.new(@amount.rescale(@currency.minor_units, mode), @currency)
    end

    # Divides the amount into one part per ratio, in proportion to the
    # ratios, as amounts at the currency's minor units that add up to
    # exactly this amount. Minor units left over by the proportional shares
    # go one each to the parts with the largest remainders, the earlier part
    # first on a tie; a ratio of 0 receives nothing.
    #
    # Raises `Decimal128::InexactError` when the amount has digits below the
    # currency's minor unit (round it first), and `ArgumentError` for no
    # ratios, a negative ratio or ratios that sum to zero.
    #
    # ```
    # Grant::Mica::Money.new("0.05", "USD").allocate([3, 7]).map(&.to_s) # => ["0.02 USD", "0.03 USD"]
    # ```
    def allocate(ratios : Array(Int)) : Array(Money)
      minor_units = @currency.minor_units
      units = @amount.rescale(minor_units, :unnecessary).coefficient
      raise ArgumentError.new("allocate needs at least one ratio") if ratios.empty?
      total_ratio = 0_u128
      ratios.each do |ratio|
        raise ArgumentError.new("allocate ratios must not be negative, got #{ratio}") if ratio < 0
        total_ratio += ratio.to_u128
      end
      raise ArgumentError.new("allocate ratios must not all be zero") if total_ratio == 0

      negative = units < 0
      magnitude = units.abs.to_u128!
      divisor = Decimal128::Wide.new(total_ratio)
      shares = Array(UInt128).new(ratios.size)
      remainders = Array(UInt128).new(ratios.size)
      allocated = 0_u128
      ratios.each do |ratio|
        share, remainder = Decimal128::Wide.divmod(Decimal128::Wide.multiply(magnitude, ratio.to_u128), divisor)
        shares << share
        remainders << remainder.low
        allocated += share
      end

      left_over = magnitude - allocated
      unless left_over == 0
        order = (0...ratios.size).to_a.sort! do |first, second|
          comparison = remainders[second] <=> remainders[first]
          comparison == 0 ? first <=> second : comparison
        end
        left_over.to_i32.times { |rank| shares[order[rank]] += 1 }
      end

      shares.map do |share|
        value = share.to_i128
        Money.new(Decimal128.new(negative ? -value : value, minor_units), @currency)
      end
    end

    # Divides the amount into *parts* equal shares at the currency's minor
    # units that add up to exactly this amount; the leftover minor units go
    # to the first parts. Raises as `allocate` does, and `ArgumentError`
    # when *parts* is below 1.
    #
    # ```
    # Grant::Mica::Money.new("100.00", "USD").split(3).map(&.to_s) # => ["33.34 USD", "33.33 USD", "33.33 USD"]
    # ```
    def split(parts : Int) : Array(Money)
      raise ArgumentError.new("split needs at least one part, got #{parts}") if parts < 1
      allocate(Array.new(parts, 1))
    end

    # Returns true when the amount is zero.
    def zero? : Bool
      @amount.zero?
    end

    # Returns true when the amount is below zero.
    def negative? : Bool
      @amount.negative?
    end

    # Returns true when both have the same currency and equal amounts, at
    # any scales (12.3 USD == 12.30 USD).
    def ==(other : Money) : Bool
      @currency == other.currency && @amount == other.amount
    end

    def hash(hasher)
      hasher = @amount.hash(hasher)
      @currency.hash(hasher)
    end

    # Writes the amount and the alpha code: `12.30 USD`.
    def to_s(io : IO) : Nil
      @amount.to_s(io)
      io << ' ' << @currency.code
    end

    # Writes the same as `to_s`.
    def inspect(io : IO) : Nil
      to_s(io)
    end

    private def same_currency(other : Money, operation : String) : Money
      return other if other.currency == @currency
      raise CurrencyMismatchError.new("cannot #{operation} #{other.currency.code} and #{@currency.code}")
    end
  end
end
