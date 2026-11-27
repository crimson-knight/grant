# Exact decimal numbers and money, with no C library and no heap allocation
# in arithmetic.
#
# `Decimal128` holds up to 38 significant digits (the range of SQL
# NUMERIC(38) and C#'s `decimal`) as an `Int128` coefficient and a scale
# from 0 to 38. Addition, subtraction and multiplication are exact and
# raise `Decimal128::OverflowError` when the exact result does not fit;
# division and rounding take an explicit result scale and `RoundingMode`.
# Nothing rounds silently.
#
# `Currency` is the ISO 4217 table (alpha code, numeric code, minor units)
# and `Money` pairs a `Decimal128` amount with a currency: arithmetic only
# between equal currencies, rounding to the currency's minor unit, and
# `allocate`/`split` that never lose or invent a minor unit.
#
# ```
# price = Grant::Mica::Decimal128.parse("19.99")
# tax = (price * Grant::Mica::Decimal128.parse("0.07")).round(2, :ties_away) # => 1.40
# total = Grant::Mica::Money.new(price + tax, "USD")                         # => 21.39 USD
# Grant::Mica::Money.new("100.00", "USD").split(3).map(&.to_s)               # => ["33.34 USD", "33.33 USD", "33.33 USD"]
# ```
#
# `require "mica/decimal"` loads these three types and nothing else. JSON,
# YAML and `BigDecimal` conversions are opt-in: `require
# "mica/decimal/json"`, `"mica/decimal/yaml"` and `"mica/decimal/big"`
# (the only file that requires "big", so only it links libgmp).
module Grant::Mica
end

require "./decimal/decimal128"
require "./decimal/errors"
require "./decimal/rounding_mode"
require "./decimal/wide"
require "./decimal/arithmetic"
require "./decimal/text"
require "./decimal/currency"
require "./decimal/currency_table"
require "./decimal/money"
