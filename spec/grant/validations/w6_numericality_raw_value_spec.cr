require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6NrOrder < Grant::Base
    connection {{ adapter_literal }}
    table w6_nr_orders

    column id : Int64, primary: true
    column quantity : Int32
    column price : Float64?
    column discount : Int32?
    column code : String?
    column plain : Int32?

    validates_numericality_of :quantity, greater_than: 0
    validates_numericality_of :price, greater_than: 0, allow_nil: true
    validates_numericality_of :discount, only_integer: true, allow_blank: true
    validates_numericality_of :code, only_numeric: true, allow_nil: true
  end
{% end %}

describe "validates_numericality_of with the raw value" do
  before_all do
    W6NrOrder.migrator.drop_and_create
  end

  it "adds :not_a_number instead of raising when text is assigned to an Int32 column" do
    order = W6NrOrder.new(quantity: "abc")
    order.valid?.should be_false
    order.errors.map(&.type).should eq([:not_a_number])
    order.errors[:quantity].should eq(["is not a number"])
    order.errors.details["quantity"].should eq([{:error => :not_a_number, :value => "abc"}])
    order.errors.any?(Grant::ConversionError).should be_false
  end

  it "judges the same input again on the next valid? call" do
    order = W6NrOrder.new(quantity: "abc")
    order.valid?.should be_false
    order.valid?.should be_false
    order.errors.size.should eq(1)
  end

  it "works through assign_attributes and update" do
    order = W6NrOrder.new(quantity: 3)
    order.assign_attributes(quantity: "twelve")
    order.valid?.should be_false
    order.errors[:quantity].should eq(["is not a number"])
  end

  it "forgets the raw input once a typed value is written" do
    order = W6NrOrder.new(quantity: "abc")
    order.valid?.should be_false
    order.quantity = 4
    order.valid?.should be_true
    order.errors.should be_empty
  end

  it "forgets the raw input once a valid value is mass-assigned" do
    order = W6NrOrder.new(quantity: "abc")
    order.valid?.should be_false
    order.assign_attributes(quantity: "7")
    order.valid?.should be_true
    order.quantity.should eq(7)
  end

  it "reports :not_an_integer for text with a fraction in an integer column" do
    order = W6NrOrder.new(quantity: "2.5")
    order.valid?.should be_false
    order.errors.map(&.type).should eq([:not_an_integer])
  end

  it "reports :out_of_range for a number that does not fit the column" do
    order = W6NrOrder.new(quantity: "99999999999")
    order.valid?.should be_false
    order.errors.map(&.type).should eq([:out_of_range])
    order.errors[:quantity].should eq(["is out of range"])
  end

  it "adds the error to a nilable column too, and save returns false without raising" do
    order = W6NrOrder.new(quantity: 1, price: "free")
    order.save.should be_false
    order.errors[:price].should eq(["is not a number"])
    W6NrOrder.count.should eq(0)
  end

  it "raises Grant::RecordInvalid from save! with the numericality message" do
    order = W6NrOrder.new(quantity: "abc")
    expect_raises(Grant::RecordInvalid, "Validation failed: Quantity is not a number") { order.save! }
  end

  it "keeps a ConversionError for an attribute without a numericality validator" do
    order = W6NrOrder.new(quantity: 1, plain: "abc")
    order.valid?.should be_false
    order.errors.any?(Grant::ConversionError).should be_true
  end

  it "keeps a ConversionError when one of several bad inputs is not claimed" do
    order = W6NrOrder.new(quantity: "abc", plain: "abc")
    order.valid?.should be_false
    order.errors.any?(Grant::ConversionError).should be_true
  end

  it "skips blank raw input with allow_blank: true" do
    order = W6NrOrder.new(quantity: 1, discount: "")
    order.valid?.should be_true
    W6NrOrder.new(quantity: 1, discount: "x").valid?.should be_false
  end

  it "rejects a Float with no fractional part under only_integer:" do
    W6NrOrder.new(quantity: 1, discount: 3).valid?.should be_true
    order = W6NrOrder.new(quantity: 1)
    order.valid?.should be_true
    Grant::Validators.integer_value?(8.0, 8.0).should be_false
    Grant::Validators.integer_value?(8, 8_i64).should be_true
    Grant::Validators.integer_value?("8", 8_i64).should be_true
  end

  it "takes a String as not numeric with only_numeric: true" do
    W6NrOrder.new(quantity: 1, code: "42").valid?.should be_false
    order = W6NrOrder.new(quantity: 1, code: "42")
    order.valid?
    order.errors.map(&.type).should eq([:not_a_number])
    W6NrOrder.new(quantity: 1).valid?.should be_true
  end

  it "does not change what a record with converted input stores" do
    order = W6NrOrder.create!(quantity: "5", price: "1.5")
    order.reload
    order.quantity.should eq(5)
    order.price.should eq(1.5)
    order.attribute_before_type_cast(:quantity).should eq(5)
  end
end
