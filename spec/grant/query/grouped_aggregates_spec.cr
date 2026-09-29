require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class GrSale < Grant::Base
    connection {{ adapter_literal }}
    table gr_sales
    column id : Int64, primary: true
    column region : String
    column channel : String
    column cents : Int64
    column weight : Float64
    column shipped_on : String?
  end
{% end %}

describe "grouped aggregates return a Hash, never a wrong scalar" do
  before_all { GrSale.migrator.drop_and_create }

  before_each do
    GrSale.clear
    GrSale.create!(region: "east", channel: "web", cents: 100_i64, weight: 1.5, shipped_on: "2026-09-01")
    GrSale.create!(region: "east", channel: "shop", cents: 300_i64, weight: 2.5, shipped_on: nil)
    GrSale.create!(region: "west", channel: "web", cents: 50_i64, weight: 0.5, shipped_on: "2026-09-03")
    GrSale.create!(region: "west", channel: "web", cents: 70_i64, weight: 1.0, shipped_on: "2026-09-05")
  end

  it "sums per group" do
    result = GrSale.group(:region).sum(:cents)
    result.should eq({"east" => 400_i64, "west" => 120_i64})
    result.as(Hash(Grant::Columns::Type, Grant::Query::Builder::SumValue)).values.each(&.should(be_a(Int64)))
  end

  it "sums float columns per group as Float64" do
    GrSale.group(:region).sum(:weight).should eq({"east" => 4.0, "west" => 1.5})
  end

  it "averages per group" do
    GrSale.group(:region).avg(:cents).should eq({"east" => 200.0, "west" => 60.0})
    GrSale.group(:region).average(:weight).should eq({"east" => 2.0, "west" => 0.75})
  end

  it "takes the minimum and maximum per group" do
    GrSale.group(:region).minimum(:cents).should eq({"east" => 100_i64, "west" => 50_i64})
    GrSale.group(:region).maximum(:cents).should eq({"east" => 300_i64, "west" => 70_i64})
    GrSale.group(:region).min(:shipped_on).should eq({"east" => "2026-09-01", "west" => "2026-09-03"})
  end

  it "keys a multi-column group by the array of values" do
    GrSale.group(:region, :channel).sum(:cents).should eq({
      ["east", "web"] => 100_i64, ["east", "shop"] => 300_i64, ["west", "web"] => 120_i64,
    })
  end

  it "groups by an expression" do
    GrSale.group("substr(shipped_on, 1, 7)").sum(:cents).should eq({"2026-09" => 220_i64, nil => 300_i64})
  end

  it "counts a column per group" do
    GrSale.group(:region).count(:shipped_on).should eq({"east" => 1_i64, "west" => 2_i64})
    GrSale.group(:region).count(:channel, distinct: true).should eq({"east" => 2_i64, "west" => 1_i64})
  end

  it "runs one GROUP BY statement for the whole result" do
    statements = capture_sql { GrSale.group(:region).sum(:cents) }
    statements.size.should eq(1)
    statements.first.should contain("SUM(")
    statements.first.should contain("GROUP BY")
    capture_sql { GrSale.group(:region, :channel).avg(:cents) }.size.should eq(1)
    capture_sql { GrSale.group(:region).max(:cents) }.size.should eq(1)
  end

  it "applies having to the groups" do
    GrSale.group(:region).having("SUM(cents) > ?", 200).sum(:cents).should eq({"east" => 400_i64})
  end

  it "applies where before grouping" do
    GrSale.where(channel: "web").group(:region).sum(:cents).should eq({"east" => 100_i64, "west" => 120_i64})
  end

  it "applies limit to the groups, in order" do
    GrSale.group(:region).order(:region).limit(1).sum(:cents).should eq({"east" => 400_i64})
  end

  it "returns an empty Hash for an empty or none relation" do
    GrSale.where(region: "north").group(:region).sum(:cents).should eq({} of Grant::Columns::Type => Grant::Query::Builder::SumValue)
    GrSale.none.group(:region).sum(:cents).as(Hash).should be_empty
    GrSale.none.group(:region).avg(:cents).as(Hash).should be_empty
    GrSale.none.group(:region).max(:cents).as(Hash).should be_empty
  end

  it "does not answer a grouped relation with a scalar" do
    GrSale.group(:region).sum(:cents).is_a?(Hash).should be_true
    GrSale.group(:region).avg(:cents).is_a?(Hash).should be_true
    GrSale.group(:region).min(:cents).is_a?(Hash).should be_true
    GrSale.group(:region).max(:cents).is_a?(Hash).should be_true
  end

  it "refuses a grouped sum across a chunked IN list" do
    ids = GrSale.order(:id).ids.map(&.as(Int64))
    expect_raises(ArgumentError, /chunked IN list/) { GrSale.where(id: ids).in_chunks(of: 2).group(:region).sum(:cents) }
  end

  it "leaves an ungrouped relation a scalar" do
    GrSale.all.sum(:cents).should eq(520_i64)
    GrSale.all.avg(:cents).should eq(130.0)
    GrSale.all.max(:cents).should eq(300_i64)
  end
end
