require "../../support/test_connection"

class G5PriceRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table g5_price_rows

  column id : Int64, primary: true
  column label : String?
  column price : Grant::Decimal128, precision: 12, scale: 2
  column rate : Grant::Decimal128?
  column wide : Grant::Decimal128?, precision: 38, scale: 10
end

class G5LedgerEntry < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table g5_ledger_entries

  column id : Int64, primary: true
  column total : Grant::Money, precision: 18, scale: 4
  column fee : Grant::Money?, precision: 10, scale: 2, currency: "USD"
end

private def decimal(text : String) : Grant::Decimal128
  Grant::Decimal128.parse(text)
end

describe "Grant::Decimal128 and Grant::Money columns on #{CURRENT_ADAPTER}" do
  before_each do
    TestConnection.ensure_registered
    G5PriceRow.migrator.drop_and_create
    G5LedgerEntry.migrator.drop_and_create
  end

  after_all do
    G5PriceRow.migrator.drop
    G5LedgerEntry.migrator.drop
  end

  it "creates the exact decimal type of each database" do
    sql = G5PriceRow.migrator.create_sql
    money_sql = G5LedgerEntry.migrator.create_sql
    case CURRENT_ADAPTER
    when "mysql"
      sql.should contain "`price` DECIMAL(12, 2) NOT NULL"
      sql.should contain "`rate` DECIMAL(18, 4)"
      sql.should contain "`wide` DECIMAL(38, 10)"
      money_sql.should contain "`total` DECIMAL(18, 4) NOT NULL"
      money_sql.should contain "`total_currency` VARCHAR(3) NOT NULL"
      money_sql.should contain "`fee` DECIMAL(10, 2)"
    when "pg"
      sql.should contain %("price" NUMERIC(12, 2) NOT NULL)
      sql.should contain %("rate" NUMERIC(18, 4))
      sql.should contain %("wide" NUMERIC(38, 10))
      money_sql.should contain %("total" NUMERIC(18, 4) NOT NULL)
      money_sql.should contain %("total_currency" VARCHAR(3) NOT NULL)
      money_sql.should contain %("fee" NUMERIC(10, 2))
    else
      sql.should contain %("price" INTEGER NOT NULL)
      sql.should contain %("rate" INTEGER)
      sql.should contain %("wide" TEXT)
      money_sql.should contain %("total" INTEGER NOT NULL)
      money_sql.should contain %("total_currency" VARCHAR(3) NOT NULL)
      money_sql.should contain %("fee" INTEGER)
    end
    money_sql.should_not contain "fee_currency"
  end

  it "builds the same column types in the create_table DSL" do
    dialect = Grant::Schema::Dialect.for(G5PriceRow.adapter)
    definition = Grant::Schema::TableDefinition.new("g5_dsl")
    definition.decimal128 :price, precision: 12, scale: 2, null: false
    definition.decimal128 :wide, precision: 38, scale: 10
    definition.money_amount :total
    definition.money_amount :fee, precision: 10, scale: 2, fixed_currency: true
    list_of_sql = definition.columns.map(&.to_sql(dialect))
    expected_price = Grant::Schema::TypeCatalog.exact_decimal_type(dialect, 12, 2)
    list_of_sql[0].should eq "#{dialect.quote("price")} #{expected_price} NOT NULL"
    list_of_sql[1].should eq "#{dialect.quote("wide")} #{Grant::Schema::TypeCatalog.exact_decimal_type(dialect, 38, 10)}"
    list_of_sql[2].should eq "#{dialect.quote("total")} #{Grant::Schema::TypeCatalog.exact_decimal_type(dialect, 18, 4)}"
    list_of_sql[3].should eq "#{dialect.quote("total_currency")} VARCHAR(3)"
    list_of_sql[4].should eq "#{dialect.quote("fee")} #{Grant::Schema::TypeCatalog.exact_decimal_type(dialect, 10, 2)}"
    list_of_sql.size.should eq 5
  end

  it "round trips 0.1 + 0.2 as exactly 0.3" do
    row = G5PriceRow.create!(price: decimal("0.1") + decimal("0.2"))
    found = G5PriceRow.find!(row.id)
    found.price.should eq decimal("0.3")
    found.price.to_s.should eq "0.30"
    G5PriceRow.where(price: decimal("0.3")).count.should eq 1
  end

  it "round trips a 38-digit value in a NUMERIC(38, 10) column" do
    value = decimal("1234567890123456789012345678.0123456789")
    neighbor = decimal("1234567890123456789012345678.0123456788")
    row = G5PriceRow.create!(price: decimal("1"), wide: value)
    found = G5PriceRow.find!(row.id)
    found.wide.should eq value
    found.wide.to_s.should eq "1234567890123456789012345678.0123456789"
    G5PriceRow.where(wide: value).count.should eq 1
    G5PriceRow.where(wide: neighbor).count.should eq 0
    G5PriceRow.find_by(wide: value).not_nil!.id.should eq row.id
  end

  it "keeps the column scale: 12.0 reads back as 12.00 and 12.30 as 12.30" do
    whole = G5PriceRow.create!(price: decimal("12.0"))
    tenths = G5PriceRow.create!(price: decimal("12.30"))
    G5PriceRow.find!(whole.id).price.to_s.should eq "12.00"
    G5PriceRow.find!(tenths.id).price.to_s.should eq "12.30"
    G5PriceRow.find!(tenths.id).price.should eq decimal("12.3")
  end

  it "round trips negatives, zero and nil" do
    row = G5PriceRow.create!(price: decimal("-0.05"), rate: decimal("0"))
    found = G5PriceRow.find!(row.id)
    found.price.to_s.should eq "-0.05"
    found.rate.to_s.should eq "0.0000"
    found.wide.should be_nil
    found.update!(rate: nil)
    G5PriceRow.find!(row.id).rate.should be_nil
  end

  it "refuses a value with more fractional digits than the scale instead of rounding" do
    row = G5PriceRow.new(price: decimal("1"))
    expect_raises(Grant::DecimalColumnError, /scale 2/) { row.price = decimal("1.005") }
    row.price.should eq decimal("1")
    row.price = decimal("1.500")
    row.price.to_s.should eq "1.50"

    mass_assigned = G5PriceRow.new(price: "2.994")
    mass_assigned.errors.map(&.field.to_s).should contain "price"
    mass_assigned.save.should be_false
    G5PriceRow.count.should eq 0
  end

  it "refuses a value with more digits than the precision" do
    row = G5PriceRow.new(price: decimal("1"))
    expect_raises(Grant::DecimalColumnError, /precision 12/) { row.price = decimal("12345678901") }
    row.price = decimal("1234567890.99")
    row.save!
    G5PriceRow.find!(row.id).price.to_s.should eq "1234567890.99"
  end

  it "parses a String in mass assignment" do
    row = G5PriceRow.new(price: "19.99")
    row.price.should eq decimal("19.99")
    row.save!
    G5PriceRow.find!(row.id).price.to_s.should eq "19.99"
    G5PriceRow.new(price: "nineteen").errors.map(&.field.to_s).should contain "price"
  end

  it "is queryable by equality, IN, comparison, find_by and sum" do
    G5PriceRow.create!(label: "a", price: decimal("10.10"))
    G5PriceRow.create!(label: "b", price: decimal("19.99"))
    G5PriceRow.create!(label: "c", price: decimal("30.00"))

    G5PriceRow.where(price: decimal("19.99")).map(&.label).should eq ["b"]
    G5PriceRow.where(price: [decimal("10.1"), decimal("30")]).order(:label).map(&.label).should eq ["a", "c"]
    G5PriceRow.where(:price, :gt, decimal("15.5")).order(:label).map(&.label).should eq ["b", "c"]
    G5PriceRow.where.lt(:price, decimal("19.99")).map(&.label).should eq ["a"]
    G5PriceRow.where("price > ?", G5PriceRow.coerce_exact_decimal_value("price", decimal("15.5"))).count.should eq 2
    G5PriceRow.where.not_in(:price, [decimal("10.10")]).count.should eq 2
    G5PriceRow.order(price: :desc).first!.label.should eq "c"
    G5PriceRow.find_by(price: decimal("30")).not_nil!.label.should eq "c"
    G5PriceRow.where(price: decimal("19.98")).exists?.should be_false

    total = G5PriceRow.sum(:price)
    total.should eq decimal("60.09")
    total.to_s.should eq "60.09"
    G5PriceRow.where(label: "zzz").sum(:price).to_s.should eq "0.00"
    G5PriceRow.where("1 = 1").sum(:price, as: Grant::Decimal128).should eq decimal("60.09")
  end

  it "sums 38-digit values exactly" do
    G5PriceRow.create!(price: decimal("1"), wide: decimal("1234567890123456789012345678.0123456789"))
    G5PriceRow.create!(price: decimal("1"), wide: decimal("0.0000000001"))
    G5PriceRow.sum(:wide).to_s.should eq "1234567890123456789012345678.0123456790"
  end

  it "tracks changes by value" do
    row = G5PriceRow.create!(price: decimal("1.00"))
    row.price = decimal("1.0")
    row.price_changed?.should be_false
    row.price = decimal("1.50")
    row.price_changed?.should be_true
    row.price_was.should eq decimal("1")
    row.save!
    G5PriceRow.find!(row.id).price.should eq decimal("1.5")
    row.update!(price: decimal("3.25"))
    row.reload.price.to_s.should eq "3.25"
  end

  it "stores Money with its currency in the companion column" do
    entry = G5LedgerEntry.create!(total: Grant::Money.new(decimal("12.30"), "EUR"))
    entry.total_currency.should eq "EUR"
    found = G5LedgerEntry.find!(entry.id)
    found.total.should eq Grant::Money.new(decimal("12.3"), "EUR")
    found.total.currency.code.should eq "EUR"
    found.total.amount.to_s.should eq "12.3000"
    found.fee.should be_nil
  end

  it "stores 100.00 USD split into 3 as rows that read back 33.34, 33.33 and 33.33" do
    parts = Grant::Money.new(decimal("100.00"), "USD").split(3)
    parts.each { |part| G5LedgerEntry.create!(total: part, fee: part) }
    list_of_totals = G5LedgerEntry.order(:id).map(&.total)
    list_of_totals.map(&.amount).should eq [decimal("33.34"), decimal("33.33"), decimal("33.33")]
    list_of_totals.all? { |money| money.currency.code == "USD" }.should be_true
    list_of_totals.map(&.amount).reduce { |sum, amount| sum + amount }.should eq decimal("100.00")
    G5LedgerEntry.sum(:total).should eq decimal("100")
    G5LedgerEntry.sum(:fee).to_s.should eq "100.00"
    G5LedgerEntry.order(:id).map(&.fee.not_nil!.amount.to_s).should eq ["33.34", "33.33", "33.33"]
  end

  it "keeps JPY, which has no minor unit" do
    entry = G5LedgerEntry.create!(total: Grant::Money.new(decimal("1500"), "JPY"))
    found = G5LedgerEntry.find!(entry.id)
    found.total.currency.code.should eq "JPY"
    found.total.currency.minor_units.should eq 0
    found.total.amount.should eq decimal("1500")
    G5LedgerEntry.where(total: Grant::Money.new(decimal("1500"), "JPY")).count.should eq 1
  end

  it "refuses Money in another currency for a fixed-currency column" do
    entry = G5LedgerEntry.new(total: Grant::Money.new(decimal("1"), "USD"))
    expect_raises(Grant::DecimalColumnError, /USD only/) { entry.fee = Grant::Money.new(decimal("5.00"), "EUR") }
    entry.fee.should be_nil
    entry.fee = Grant::Money.new(decimal("5.00"), "USD")
    entry.save!
    G5LedgerEntry.find!(entry.id).fee.should eq Grant::Money.new(decimal("5"), "USD")
  end

  it "refuses a Money amount past the column scale" do
    entry = G5LedgerEntry.new(total: Grant::Money.new(decimal("1"), "USD"))
    expect_raises(Grant::DecimalColumnError, /scale 2/) { entry.fee = Grant::Money.new(decimal("0.001"), "USD") }
  end

  it "parses Money from a String in mass assignment" do
    entry = G5LedgerEntry.new(total: "19.99 EUR", fee: "2.50")
    entry.errors.should be_empty
    entry.total.should eq Grant::Money.new(decimal("19.99"), "EUR")
    entry.fee.should eq Grant::Money.new(decimal("2.5"), "USD")
    entry.save!
    G5LedgerEntry.find!(entry.id).total.to_s.should eq "19.9900 EUR"
    G5LedgerEntry.new(total: "19.99").errors.map(&.field.to_s).should contain "total"
  end

  it "tracks a currency change on a Money column" do
    entry = G5LedgerEntry.create!(total: Grant::Money.new(decimal("10"), "USD"))
    entry.total = Grant::Money.new(decimal("10.00"), "USD")
    entry.total_changed?.should be_false
    entry.total = Grant::Money.new(decimal("10"), "EUR")
    entry.total_changed?.should be_true
    entry.total_currency_changed?.should be_true
    entry.save!
    G5LedgerEntry.find!(entry.id).total.currency.code.should eq "EUR"
  end
end
