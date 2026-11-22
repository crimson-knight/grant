# The control for `scripts/check_gmp_linkage.rb`: a program that opts in to
# BigDecimal support must show GMP, which proves the check can fail. It also
# stores and reads back a decimal column.
require "../../src/grant/big_decimal"
require "../../src/grant"
require "../../src/adapter/sqlite"

Grant::Connections << Grant::Adapter::Sqlite.new(name: "primary", url: "sqlite3::memory:")

class Invoice < Grant::Base
  connection primary
  table invoices

  column id : Int64, primary: true
  column total_due : BigDecimal, precision: 12, scale: 2
end

Invoice.migrator.drop_and_create
Invoice.create!(total_due: BigDecimal.new("1250.755"))
puts Invoice.first!.total_due
puts Invoice.sum(:total_due)
