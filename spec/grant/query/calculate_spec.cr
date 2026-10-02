require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CaRow < Grant::Base
    connection {{ adapter_literal }}
    table ca_rows
    column id : Int64, primary: true
    column team : String
    column points : Int64
  end
{% end %}

describe "calculate" do
  before_all { CaRow.migrator.drop_and_create }

  before_each do
    CaRow.clear
    CaRow.create!(team: "red", points: 4_i64)
    CaRow.create!(team: "red", points: 6_i64)
    CaRow.create!(team: "blue", points: 10_i64)
  end

  it "dispatches to the named aggregates" do
    relation = CaRow.all
    relation.calculate(:count).should eq(3_i64)
    relation.calculate(:count, :points).should eq(3_i64)
    relation.calculate(:sum, :points).should eq(20_i64)
    relation.calculate(:average, :points).should eq(20.0 / 3)
    relation.calculate(:avg, :points).should eq(20.0 / 3)
    relation.calculate(:minimum, :points).should eq(4_i64)
    relation.calculate(:min, :points).should eq(4_i64)
    relation.calculate(:maximum, :points).should eq(10_i64)
    relation.calculate(:max, :points).should eq(10_i64)
  end

  it "takes a Grant::Calculation" do
    CaRow.all.calculate(Grant::Calculation::Sum, "points").should eq(20_i64)
    CaRow.calculate(Grant::Calculation::Count).should eq(3_i64)
  end

  it "returns a Hash per group" do
    CaRow.group(:team).calculate(:sum, :points).should eq({"red" => 10_i64, "blue" => 10_i64})
    CaRow.group(:team).calculate(:count).should eq({"red" => 2_i64, "blue" => 1_i64})
    CaRow.group(:team).calculate(:maximum, :points).should eq({"red" => 6_i64, "blue" => 10_i64})
  end

  it "is available on the model class" do
    CaRow.calculate(:sum, :points).should eq(20_i64)
  end

  it "raises for an unknown operation or a missing column" do
    expect_raises(ArgumentError, /Unknown calculation :median/) { CaRow.all.calculate(:median, :points) }
    expect_raises(ArgumentError, /needs a column/) { CaRow.all.calculate(:sum) }
  end

  it "maps every symbol to a Calculation" do
    {count: Grant::Calculation::Count, sum: Grant::Calculation::Sum, average: Grant::Calculation::Average,
     avg: Grant::Calculation::Average, minimum: Grant::Calculation::Minimum, min: Grant::Calculation::Minimum,
     maximum: Grant::Calculation::Maximum, max: Grant::Calculation::Maximum}.each do |name, expected|
      Grant::Calculation.from_symbol(name).should eq(expected)
    end
  end
end
