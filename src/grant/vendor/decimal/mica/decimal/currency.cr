module Grant::Mica
  # An ISO 4217 currency: its alpha code, numeric code and minor units (the
  # digits after the point of its smallest unit: USD 2, JPY 0, BHD 3).
  # `TABLE` holds every current code.
  #
  # ```
  # Grant::Mica::Currency.find("BHD").minor_units # => 3
  # Grant::Mica::Currency.find?("ZZZ")            # => nil
  # ```
  struct Currency
    # Base class of every error `Currency` raises.
    class Error < Exception
    end

    # Raised by `Currency.find` for a code that is not a current ISO 4217
    # currency.
    class UnknownError < Error
    end

    # Raised by `#minor_units` for a code ISO 4217 gives no minor unit
    # ("N.A."): precious metals, SDR, test and fund codes such as XAU.
    class NoMinorUnitsError < Error
    end

    # The three-letter alpha code, such as "USD".
    getter code : String

    # The numeric code, such as 840 for USD (ISO writes it with three
    # digits: 008 for ALL).
    getter numeric_code : Int32

    def initialize(@code : String, @numeric_code : Int32, @minor_units : Int32?)
    end

    # Returns the currency with alpha *code* (upper case, as ISO 4217
    # writes it). Raises `UnknownError` for any other code.
    def self.find(code : String) : Currency
      find?(code) || raise UnknownError.new("#{code.inspect} is not a current ISO 4217 currency code")
    end

    # Returns the currency with alpha *code*, or nil.
    def self.find?(code : String) : Currency?
      TABLE[code]?
    end

    # Returns every current currency, ordered by alpha code.
    def self.all : Array(Currency)
      TABLE.values
    end

    # Returns the digits after the point of the smallest unit. Raises
    # `NoMinorUnitsError` for a code without one (see `#minor_units?`).
    def minor_units : Int32
      @minor_units || raise NoMinorUnitsError.new("ISO 4217 gives #{@code} no minor unit")
    end

    # Returns the digits after the point of the smallest unit, or nil for
    # a code ISO 4217 gives none (XAU, XDR, XXX and the like).
    def minor_units? : Int32?
      @minor_units
    end

    # Returns true when both are the same currency.
    def ==(other : Currency) : Bool
      @code == other.code
    end

    def hash(hasher)
      @code.hash(hasher)
    end

    # Writes the alpha code.
    def to_s(io : IO) : Nil
      io << @code
    end
  end
end
