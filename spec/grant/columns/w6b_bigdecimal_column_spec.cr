require "big"
require "../../support/test_connection"

class W6bPriceRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6b_price_rows

  column id : Int64, primary: true
  column label : String?
  column price : BigDecimal, precision: 12, scale: 2
  column discount : BigDecimal?, precision: 5, scale: 2
  column ratio : BigDecimal?
end

describe "BigDecimal model columns on #{CURRENT_ADAPTER}" do
  before_each do
    TestConnection.ensure_registered
    W6bPriceRow.migrator.drop_and_create
  end

  after_all { W6bPriceRow.migrator.drop }

  it "maps precision and scale to the decimal type of the dialect" do
    sql = W6bPriceRow.migrator.create_sql
    case CURRENT_ADAPTER
    when "mysql"
      sql.should contain "`price` DECIMAL(12, 2) NOT NULL"
      sql.should contain "`discount` DECIMAL(5, 2)"
      sql.should contain "`ratio` DECIMAL"
    else
      sql.should contain %("price" NUMERIC(12, 2) NOT NULL)
      sql.should contain %("discount" NUMERIC(5, 2)\n)
      sql.should contain %("ratio" NUMERIC\n)
    end
  end

  it "round trips values without losing digits" do
    row = W6bPriceRow.create!(label: "a", price: BigDecimal.new("12345678.91"), discount: BigDecimal.new("0.50"))
    found = W6bPriceRow.find!(row.id)
    found.price.should eq BigDecimal.new("12345678.91")
    found.price.should be_a BigDecimal
    found.discount.should eq BigDecimal.new("0.5")
    found.ratio.should be_nil
  end

  it "rounds to the declared scale on assignment, as on every adapter" do
    row = W6bPriceRow.new(price: BigDecimal.new("1.005"))
    row.price.should eq BigDecimal.new("1.01")
    row.price = BigDecimal.new("2.994")
    row.price.should eq BigDecimal.new("2.99")
    row.save!
    W6bPriceRow.find!(row.id).price.should eq BigDecimal.new("2.99")
  end

  it "accepts a numeric string in mass assignment" do
    row = W6bPriceRow.new(price: "19.99")
    row.price.should eq BigDecimal.new("19.99")
  end

  it "is queryable by equality, comparison, IN, find_by and sum" do
    W6bPriceRow.create!(label: "a", price: BigDecimal.new("10.10"))
    W6bPriceRow.create!(label: "b", price: BigDecimal.new("19.99"))
    W6bPriceRow.create!(label: "c", price: BigDecimal.new("30.00"))

    W6bPriceRow.where(price: BigDecimal.new("19.99")).map(&.label).should eq ["b"]
    W6bPriceRow.where(price: [BigDecimal.new("10.10"), BigDecimal.new("30.00")]).order(:label).map(&.label).should eq ["a", "c"]
    W6bPriceRow.where("price > ?", BigDecimal.new("15.5")).order(:label).map(&.label).should eq ["b", "c"]
    W6bPriceRow.where(:price, :gt, BigDecimal.new("15.5")).count.should eq 2
    W6bPriceRow.order(price: :desc).first!.label.should eq "c"
    W6bPriceRow.sum(:price).should eq BigDecimal.new("60.09")
    W6bPriceRow.where(price: BigDecimal.new("19.99")).exists?.should be_true
    W6bPriceRow.where(price: BigDecimal.new("19.98")).exists?.should be_false
    W6bPriceRow.find_by(price: BigDecimal.new("30")).not_nil!.label.should eq "c"
  end

  it "tracks changes and updates" do
    row = W6bPriceRow.create!(price: BigDecimal.new("1.00"))
    row.price_changed?.should be_false
    row.price = BigDecimal.new("1.50")
    row.price_changed?.should be_true
    row.save!
    W6bPriceRow.find!(row.id).price.should eq BigDecimal.new("1.5")
    row.update!(price: BigDecimal.new("3.25"))
    row.reload.price.should eq BigDecimal.new("3.25")
  end

  it "stores nil in a nilable column" do
    # A DECIMAL with no precision is DECIMAL(10, 0) on MySQL, so it keeps no
    # fraction there.
    ratio = BigDecimal.new(CURRENT_ADAPTER == "mysql" ? "42" : "0.333333333333")
    row = W6bPriceRow.create!(price: BigDecimal.new("1"), ratio: ratio)
    W6bPriceRow.find!(row.id).ratio.should eq ratio
    row.update!(ratio: nil)
    W6bPriceRow.find!(row.id).ratio.should be_nil
  end
end
