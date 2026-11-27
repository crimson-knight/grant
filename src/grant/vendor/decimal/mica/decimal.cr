# TEMPORARY development stub of Mica's decimal component (contract only).
# Replaced by scripts/vendor_into.rb output before merge.
module Grant::Mica
  struct Decimal128
    include Comparable(Decimal128)

    class Error < Exception; end

    class ParseError < Error; end

    class OverflowError < Error; end

    class DivisionByZeroError < Error; end

    class InexactError < Error; end

    enum RoundingMode
      TiesAway
      TiesEven
      Floor
      Ceiling
      Truncate
      Unnecessary
    end

    MAX_COEFFICIENT = Int128.new(10) ** 38 - 1

    getter coefficient : Int128
    getter scale : Int32

    def initialize(coefficient : Int, scale : Int32 = 0)
      @coefficient = coefficient.to_i128
      @scale = scale
      raise OverflowError.new("too many digits") if @coefficient.abs > MAX_COEFFICIENT
      raise OverflowError.new("scale out of range") unless 0 <= scale <= 38
    end

    def self.parse(text : String) : Decimal128
      parse?(text) || raise ParseError.new("Invalid decimal: #{text.inspect}")
    end

    def self.parse?(text : String) : Decimal128?
      text = text.strip
      body_text = text.lchop('-').lchop('+')
      return nil if body_text.empty? || body_text == "." || body_text.count('.') > 1
      return nil unless body_text.each_char.all? { |char| char.ascii_number? || char == '.' }
      negative = text.starts_with?('-')
      body = text.lchop('-').lchop('+')
      whole, _, fraction = body.partition('.')
      digits = (whole + fraction).lstrip('0')
      digits = "0" if digits.empty?
      return nil if digits.size > 38 || fraction.size > 38
      coefficient = digits.to_i128
      new(negative ? -coefficient : coefficient, fraction.size)
    end

    def to_s(io : IO) : Nil
      digits = @coefficient.abs.to_s
      io << '-' if @coefficient < 0
      if @scale == 0
        io << digits
      else
        digits = digits.rjust(@scale + 1, '0')
        io << digits[0, digits.size - @scale] << '.' << digits[-@scale..]
      end
    end

    def rescale(scale : Int32, mode : RoundingMode = :unnecessary) : Decimal128
      return self if scale == @scale
      if scale > @scale
        Decimal128.new(@coefficient * Int128.new(10) ** (scale - @scale), scale)
      else
        factor = Int128.new(10) ** (@scale - scale)
        quotient = @coefficient.tdiv(factor)
        remainder = @coefficient - quotient * factor
        raise InexactError.new("#{self} needs more than #{scale} fractional digits") if remainder != 0 && mode.unnecessary?
        if remainder != 0 && mode.ties_away? && remainder.abs * 2 >= factor
          quotient += @coefficient < 0 ? -1 : 1
        end
        Decimal128.new(quotient, scale)
      end
    end

    def round(scale : Int32, mode : RoundingMode) : Decimal128
      rescale(scale, mode)
    end

    private def aligned(other : Decimal128) : {Int128, Int128, Int32}
      scale = {@scale, other.scale}.max
      {rescale(scale).coefficient, other.rescale(scale).coefficient, scale}
    end

    def +(other : Decimal128) : Decimal128
      a, b, s = aligned(other)
      Decimal128.new(a + b, s)
    end

    def -(other : Decimal128) : Decimal128
      a, b, s = aligned(other)
      Decimal128.new(a - b, s)
    end

    def *(other : Decimal128) : Decimal128
      Decimal128.new(@coefficient * other.coefficient, @scale + other.scale)
    end

    def - : Decimal128
      Decimal128.new(-@coefficient, @scale)
    end

    def <=>(other : Decimal128) : Int32
      a, b, _ = aligned(other)
      a <=> b
    end

    def ==(other : Decimal128) : Bool
      (self <=> other) == 0
    end

    def ==(other) : Bool
      false
    end

    def hash(hasher)
      c, s = @coefficient, @scale
      while s > 0 && c % 10 == 0
        c = c.tdiv(10)
        s -= 1
      end
      hasher = c.hash(hasher)
      s.hash(hasher)
    end

    def precision : Int32
      @coefficient.abs.to_s.size
    end

    def zero? : Bool
      @coefficient == 0
    end

    def negative? : Bool
      @coefficient < 0
    end

    def to_i64 : Int64
      rescale(0, :truncate).coefficient.to_i64
    end

    def to_f64 : Float64
      to_s.to_f64
    end
  end

  struct Currency
    class UnknownError < Exception; end

    getter code : String
    getter numeric_code : Int32
    getter minor_units : Int32

    def initialize(@code, @numeric_code, @minor_units)
    end

    TABLE = {"USD" => {840, 2}, "JPY" => {392, 0}, "EUR" => {978, 2}, "BHD" => {48, 3}}

    def self.find?(code : String) : Currency?
      if entry = TABLE[code.upcase]?
        new(code.upcase, entry[0], entry[1])
      end
    end

    def self.find(code : String) : Currency
      find?(code) || raise UnknownError.new("Unknown currency #{code}")
    end

    def ==(other : Currency) : Bool
      code == other.code
    end
  end

  struct Money
    class CurrencyMismatchError < Exception; end

    getter amount : Decimal128
    getter currency : Currency

    def initialize(amount : Decimal128 | String | Int, currency : Currency | String)
      @amount = case amount
                when Decimal128 then amount
                when String     then Decimal128.parse(amount)
                else                 Decimal128.new(amount)
                end
      @currency = currency.is_a?(String) ? Currency.find(currency) : currency
    end

    def +(other : Money) : Money
      raise CurrencyMismatchError.new("#{currency.code} vs #{other.currency.code}") unless currency == other.currency
      Money.new(amount + other.amount, currency)
    end

    def split(parts : Int) : Array(Money)
      units = @amount.rescale(currency.minor_units).coefficient
      base = units.tdiv(parts)
      extra = units - base * parts
      Array(Money).new(parts) do |index|
        Money.new(Decimal128.new(base + (index < extra ? 1 : 0), currency.minor_units), currency)
      end
    end

    def ==(other : Money) : Bool
      amount == other.amount && currency == other.currency
    end

    def to_s(io : IO) : Nil
      io << amount << ' ' << currency.code
    end
  end
end
