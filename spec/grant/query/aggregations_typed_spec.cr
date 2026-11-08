require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class AtLedger < Grant::Base
    connection {{ adapter_literal }}
    table at_ledgers
    column id : Int64, primary: true
    column kind : String
    column cents : Int64
    column ratio : Float64
    column note : String?
  end
{% end %}

BEYOND_FLOAT_PRECISION = 9_007_199_254_740_993_i64 # 2**53 + 1: not a Float64

describe "typed aggregations" do
  before_all { AtLedger.migrator.drop_and_create }

  before_each do
    AtLedger.clear
    AtLedger.create!(kind: "a", cents: 10_i64, ratio: 0.5, note: "x")
    AtLedger.create!(kind: "a", cents: 10_i64, ratio: 1.25, note: "x")
    AtLedger.create!(kind: "b", cents: 30_i64, ratio: 2.0, note: nil)
  end

  it "delegates assembler last to the relation's typed finder" do
    AtLedger.where(kind: "a").order(:id).assembler.last.try(&.cents).should eq(10_i64)
  end

  describe "count" do
    it "counts rows with a value for a column" do
      AtLedger.count.should eq(3_i64)
      AtLedger.all.count(:note).should eq(2_i64)
      AtLedger.count(:note).should eq(2_i64)
      AtLedger.all.count("note").should eq(2_i64)
    end

    it "treats :all and * as the plain count" do
      AtLedger.all.count(:all).should eq(3_i64)
      AtLedger.all.count("*").should eq(3_i64)
    end

    it "counts distinct values with COUNT(DISTINCT column) in one statement" do
      AtLedger.all.count(:cents, distinct: true).should eq(2_i64)
      AtLedger.all.count(:note, distinct: true).should eq(1_i64)
      AtLedger.count(:cents, distinct: true).should eq(2_i64)
      sql = AtLedger.all.assembler.aggregate_sql("COUNT", "cents", :none, true)
      sql.should contain("COUNT(DISTINCT")
      sql.should_not contain("FROM (")
    end

    it "counts distinct values for a relation made distinct" do
      AtLedger.distinct.count(:cents).should eq(2_i64)
    end

    it "honors where, limit and offset" do
      AtLedger.where(kind: "a").count(:cents).should eq(2_i64)
      AtLedger.order(:id).limit(2).count(:note).should eq(2_i64)
      AtLedger.order(:id).offset(2).count(:note).should eq(0_i64)
    end

    it "returns a Hash per group" do
      AtLedger.group(:kind).count(:note).should eq({"a" => 2_i64, "b" => 0_i64})
    end

    it "needs a column for distinct" do
      expect_raises(ArgumentError, /needs a column/) { AtLedger.all.count(:all, distinct: true) }
    end
  end

  describe "sum" do
    it "sums an integer column exactly as Int64" do
      result = AtLedger.sum(:cents)
      result.should be_a(Int64)
      result.should eq(50_i64)
      AtLedger.where(kind: "a").sum(:cents).should eq(20_i64)
    end

    it "keeps every digit of a BIGINT sum above 2**53" do
      AtLedger.clear
      AtLedger.create!(kind: "big", cents: BEYOND_FLOAT_PRECISION, ratio: 0.0)
      AtLedger.create!(kind: "big", cents: BEYOND_FLOAT_PRECISION, ratio: 0.0)
      total = AtLedger.all.sum(:cents)
      total.should be_a(Int64)
      total.should eq(BEYOND_FLOAT_PRECISION * 2)
      # A Float64 sum would have rounded to an even value 2**54 + 2.
      (BEYOND_FLOAT_PRECISION * 2).to_f64.to_i64.should_not eq(BEYOND_FLOAT_PRECISION * 2)
    end

    it "sums a float column as Float64" do
      result = AtLedger.sum(:ratio)
      result.should be_a(Float64)
      result.should eq(3.75)
    end

    it "sums an expression as an exact number" do
      result = AtLedger.all.sum("cents * 2")
      result.should be_a(Int64)
      result.should eq(100_i64)
    end

    it "returns the requested type with as:" do
      AtLedger.all.sum(:cents, as: Int64).should eq(50_i64)
      AtLedger.all.sum(:cents, as: Float64).should eq(50.0)
      decimal = AtLedger.all.sum(:ratio, as: BigDecimal)
      decimal.should be_a(BigDecimal)
      decimal.should eq(BigDecimal.new("3.75"))
      AtLedger.all.sum(:cents, as: BigDecimal).should eq(BigDecimal.new(50))
    end

    it "refuses an Int64 result for a fractional sum" do
      expect_raises(ArgumentError, /does not fit Int64/) { AtLedger.all.sum(:ratio, as: Int64) }
    end

    it "sums an empty relation to zero of the column's type" do
      empty = AtLedger.where(kind: "nothing")
      empty.sum(:cents).should eq(0_i64)
      empty.sum(:cents).should be_a(Int64)
      empty.sum(:ratio).should eq(0.0)
      empty.sum(:ratio).should be_a(Float64)
      AtLedger.none.sum(:cents).should eq(0_i64)
    end

    it "honors limit, offset, distinct and having" do
      AtLedger.order(:id).limit(2).sum(:cents).should eq(20_i64)
      AtLedger.order(:id).offset(2).sum(:cents).should eq(30_i64)
      AtLedger.distinct.sum(:cents).should eq(40_i64)
    end

    it "sums across an IN list that is chunked" do
      ids = AtLedger.order(:id).ids.map(&.as(Int64))
      AtLedger.where(id: ids).in_chunks(of: 2).sum(:cents).should eq(50_i64)
      AtLedger.where(id: ids).in_chunks(of: 2).sum(:ratio).should eq(3.75)
      AtLedger.where(id: ids).in_chunks(of: 2).sum(:cents, as: BigDecimal).should eq(BigDecimal.new(50))
    end
  end

  describe "avg, min and max" do
    it "computes them over the relation" do
      AtLedger.avg(:cents).should eq(50.0 / 3)
      AtLedger.average(:ratio).should eq(1.25)
      AtLedger.minimum(:cents).should eq(10_i64)
      AtLedger.maximum(:cents).should eq(30_i64)
      AtLedger.where(kind: "nothing").avg(:cents).should be_nil
      AtLedger.where(kind: "nothing").min(:cents).should be_nil
    end

    it "honors limit and offset" do
      AtLedger.order(:id).limit(2).avg(:cents).should eq(10.0)
      AtLedger.order(:id).offset(2).max(:cents).should eq(30_i64)
      AtLedger.order(:id).limit(1).offset(1).min(:cents).should eq(10_i64)
    end

    it "combines chunked IN lists" do
      ids = AtLedger.order(:id).ids.map(&.as(Int64))
      chunked = AtLedger.where(id: ids).in_chunks(of: 2)
      chunked.avg(:cents).should eq(50.0 / 3)
      chunked.min(:cents).should eq(10_i64)
      chunked.max(:cents).should eq(30_i64)
    end
  end

  it "raises when the class-level scalar is asked of a grouped scope" do
    AtLedger.group(:kind).sum(:cents).should be_a(Hash(Grant::Columns::Type, Grant::Query::Builder::SumValue))
  end
end
