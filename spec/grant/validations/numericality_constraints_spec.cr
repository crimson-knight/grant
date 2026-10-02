require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class V02nOrder < Grant::Base
    connection {{ adapter_literal }}
    table v02n_orders

    column id : Int64, primary: true
    column price : Float64?
    column quantity : Int32?
    column minimum : Int32?
    column maximum : Int32?
    column ceiling : Int32?
    column score : Int32?
    column level : Int32?
    column exact : Int32?
    column other : Int32?
    column label : String?
    column optional : Int32?
    column ratio : Float64?

    validates_numericality_of :price, greater_than: 0, message: "must be positive", if: :check_price?
    validates_numericality_of :quantity, only_integer: true, greater_than: 0, odd: true, if: :check_quantity?
    validates_numericality_of :maximum, greater_than: :minimum, if: :check_bounds?
    validates_numericality_of :ceiling, less_than_or_equal_to: ->(order : V02nOrder) { order.maximum || 0 }, if: :check_ceiling?
    validates_numericality_of :score, in: 1..10, if: :check_score?
    validates_numericality_of :level, in: 1...5, if: :check_level?
    validates_numericality_of :exact, equal_to: 7, if: :check_exact?
    validates_numericality_of :other, other_than: 0, less_than: 100, if: :check_other?
    validates_numericality_of :label, if: :check_label?
    validates_numericality_of :ratio, only_integer: true, greater_than: 5, if: :check_ratio?
    validates_numericality_of :optional, greater_than: 0, allow_nil: true

    property mode : Symbol = :none

    {% for name in %w[price quantity bounds ceiling score level exact other label ratio] %}
      def check_{{name.id}}?
        mode == :{{name.id}}
      end
    {% end %}
  end
{% end %}

private def v02n_order(mode : Symbol, **attributes)
  order = V02nOrder.new(**attributes)
  order.mode = mode
  order.valid?
  order
end

describe "validates_numericality_of constraints" do
  before_all do
    V02nOrder.migrator.drop_and_create
  end

  describe "one error per failed constraint" do
    it "adds a separate error, with its own type, for each failing constraint" do
      order = v02n_order(:quantity, quantity: -4)
      order.errors.map(&.type).should eq([:greater_than, :odd])
      order.errors[:quantity].should eq(["must be greater than 0", "must be odd"])
    end

    it "reports every constraint's count and the offending value in details" do
      order = v02n_order(:quantity, quantity: -4)
      order.errors.details["quantity"].should eq([
        {:error => :greater_than, :count => 0, :value => -4},
        {:error => :odd, :value => -4},
      ])
    end

    it "stops at not_an_integer, like ActiveRecord" do
      order = v02n_order(:ratio, ratio: 1.5)
      order.errors.map(&.type).should eq([:not_an_integer])
      order.errors.first.message.should eq("must be an integer")
      # A Float with no fractional part is still not an integer, as in ActiveRecord.
      v02n_order(:ratio, ratio: 8.0).errors.map(&.type).should eq([:not_an_integer])
    end

    it "reports nil as not_a_number" do
      order = v02n_order(:quantity, quantity: nil)
      order.errors.map(&.type).should eq([:not_a_number])
      order.errors.first.message.should eq("is not a number")
    end

    it "passes when every constraint holds" do
      v02n_order(:quantity, quantity: 3).errors.should be_empty
    end

    it "applies a custom message to each error" do
      order = v02n_order(:price, price: -1.5)
      order.errors[:price].should eq(["must be positive"])
      order.errors.first.type.should eq(:greater_than)
    end
  end

  describe "Symbol and Proc operands" do
    it "reads a Symbol operand from the record" do
      order = v02n_order(:bounds, minimum: 10, maximum: 5)
      order.errors.details["maximum"].should eq([{:error => :greater_than, :count => 10, :value => 5}])
      order.errors[:maximum].should eq(["must be greater than 10"])
      v02n_order(:bounds, minimum: 1, maximum: 5).errors.should be_empty
    end

    it "calls a Proc operand with the record" do
      order = v02n_order(:ceiling, maximum: 5, ceiling: 9)
      order.errors.details["ceiling"].should eq([{:error => :less_than_or_equal_to, :count => 5, :value => 9}])
      v02n_order(:ceiling, maximum: 5, ceiling: 5).errors.should be_empty
    end

    it "raises when an operand does not resolve to a number" do
      order = V02nOrder.new(maximum: 5)
      order.mode = :bounds
      expect_raises(ArgumentError, /greater_than must be a number/) { order.valid? }
    end
  end

  describe "equal_to, other_than and in:" do
    it "checks equal_to" do
      v02n_order(:exact, exact: 7).errors.should be_empty
      order = v02n_order(:exact, exact: 8)
      order.errors.details["exact"].should eq([{:error => :equal_to, :count => 7, :value => 8}])
      order.errors[:exact].should eq(["must be equal to 7"])
    end

    it "checks other_than together with another bound" do
      order = v02n_order(:other, other: 0)
      order.errors.map(&.type).should eq([:other_than])
      order = v02n_order(:other, other: 100)
      order.errors.map(&.type).should eq([:less_than])
      v02n_order(:other, other: 5).errors.should be_empty
    end

    it "maps in: to the lower and upper bound errors" do
      v02n_order(:score, score: 5).errors.should be_empty
      v02n_order(:score, score: 1).errors.should be_empty
      v02n_order(:score, score: 10).errors.should be_empty
      low = v02n_order(:score, score: 0)
      low.errors.details["score"].should eq([{:error => :greater_than_or_equal_to, :count => 1, :value => 0}])
      high = v02n_order(:score, score: 11)
      high.errors.details["score"].should eq([{:error => :less_than_or_equal_to, :count => 10, :value => 11}])
    end

    it "treats an exclusive range end as less_than" do
      v02n_order(:level, level: 4).errors.should be_empty
      order = v02n_order(:level, level: 5)
      order.errors.details["level"].should eq([{:error => :less_than, :count => 5, :value => 5}])
    end

    it "reports a nil value as not_a_number and skips it with allow_nil" do
      order = v02n_order(:score, score: nil)
      order.errors.details["score"].should eq([{:error => :not_a_number, :value => nil}])
      V02nOrder.new(optional: nil).valid?.should be_true
      V02nOrder.new(optional: 0).valid?.should be_false
    end

    it "parses numeric strings" do
      order = V02nOrder.new
      Grant::Validators.numeric_value("12").should eq(12)
      Grant::Validators.numeric_value("1.5").should eq(1.5)
      Grant::Validators.numeric_value("abc").should be_nil
      Grant::Validators.numeric_value(Float64::NAN).should be_nil
    end
  end

  describe "reflection" do
    it "exposes the numericality validators and their options" do
      info = V02nOrder.validators_on(:quantity).first
      info.kind.should eq(:numericality)
      info.option(:greater_than).should eq(0)
      info.option(:only_integer).should be_true
      info.conditional?.should be_true
    end
  end
end
