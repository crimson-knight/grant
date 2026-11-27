module Grant::Mica
  struct Decimal128
    # Base class of every error `Decimal128` raises. Rescue it to handle
    # all of them.
    class Error < Exception
    end

    # Raised by `Decimal128.parse` for text that is not a decimal number:
    # an optional sign, digits, an optional `.` and fraction digits, and an
    # optional exponent (`e` or `E`, an optional sign, digits).
    class ParseError < Error
    end

    # Raised when an exact result needs more than 38 digits or a scale
    # above 38. Nothing is rounded instead.
    class OverflowError < Error
    end

    # Raised by `Decimal128#divide` when the divisor is zero.
    class DivisionByZeroError < Error
    end

    # Raised by `RoundingMode::Unnecessary` (the default of `rescale`) when
    # rounding would drop a nonzero digit.
    class InexactError < Error
    end
  end
end
