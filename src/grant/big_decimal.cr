# BigDecimal support for Grant, opt-in. Grant's default path requires `big`
# nowhere, so an app without decimal columns links no GMP. Require this file
# before `grant` to enable:
#
# - `column price : BigDecimal` (with `precision:` and `scale:`), stored as
#   exact decimal text in a `NUMERIC`/`DECIMAL` column
# - `BigDecimal` and `Array(BigDecimal)` in `Grant::Columns::Type`: query
#   arguments, mass assignment and dirty tracking
# - `BigDecimal` column defaults in schema statements
# - exact `BigDecimal` sums: `sum(:price)` on a decimal column or expression
#   and `sum(:price, as: BigDecimal)`
#
# ```
# require "grant/big_decimal"
# require "grant"
# require "grant/adapter/sqlite"
# ```
#
# The types above are fixed as Grant loads, which is why the require comes
# first. An app that already requires `big` before `grant` has the support
# without this file.
{% if @top_level.has_constant?("Grant") && Grant.has_constant?("BIG_DECIMAL_SUPPORT") %}
  {% unless Grant::BIG_DECIMAL_SUPPORT %}
    {% raise "Grant is already loaded without BigDecimal support: move `require \"grant/big_decimal\"` before `require \"grant\"`." %}
  {% end %}
{% end %}

require "big"
require "../grant"
