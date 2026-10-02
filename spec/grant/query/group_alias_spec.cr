require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class GaOrder < Grant::Base
    connection {{ adapter_literal }}
    table ga_orders
    column id : Int64, primary: true
    column status : String
    column region : String
    column cents : Int64
    column placed_on : String
  end
{% end %}

describe "group as the ActiveRecord name for group_by" do
  before_all { GaOrder.migrator.drop_and_create }

  before_each do
    GaOrder.clear
    GaOrder.create!(status: "open", region: "east", cents: 100_i64, placed_on: "2026-09-27 10:00:00")
    GaOrder.create!(status: "open", region: "west", cents: 250_i64, placed_on: "2026-09-27 12:00:00")
    GaOrder.create!(status: "done", region: "east", cents: 400_i64, placed_on: "2026-09-28 09:00:00")
  end

  it "answers group like group_by" do
    GaOrder.group(:status).raw_sql.should eq(GaOrder.group_by(:status).raw_sql)
    GaOrder.group(:status, :region).raw_sql.should eq(GaOrder.group_by([:status, :region]).raw_sql)
    GaOrder.all.group(:status).count.should eq({"open" => 2_i64, "done" => 1_i64})
    GaOrder.group(:status, :region).count.should eq({
      ["open", "east"] => 1_i64, ["open", "west"] => 1_i64, ["done", "east"] => 1_i64,
    })
  end

  it "keeps group_by working" do
    GaOrder.group_by(:status).count.should eq({"open" => 2_i64, "done" => 1_i64})
  end

  it "groups by a SQL expression" do
    counts = GaOrder.group("substr(placed_on, 1, 10)").count
    counts.should eq({"2026-09-27" => 2_i64, "2026-09-28" => 1_i64})
    GaOrder.group_by("substr(placed_on, 1, 10)").count.should eq(counts)
  end

  it "mixes columns and expressions across calls" do
    GaOrder.group(:status).group("substr(placed_on, 1, 10)").count.should eq({
      ["open", "2026-09-27"] => 2_i64, ["done", "2026-09-28"] => 1_i64,
    })
  end

  it "has a bang form, and unscope drops the grouping" do
    relation = GaOrder.all
    relation.group!(:status)
    relation.group_fields.size.should eq(1)
    relation.unscope(:group).group_fields.should be_empty
    GaOrder.group(:status).regroup(:region).group_fields.map(&.[:field]).should eq(["region"])
  end

  it "does not change the receiver" do
    base = GaOrder.where(status: "open")
    base.group(:region)
    base.group("lower(region)")
    base.group_fields.should be_empty
  end

  it "refuses an expression that is not a single clause" do
    expect_raises(ArgumentError, /statement separator/) { GaOrder.group("status; DELETE FROM ga_orders") }
    expect_raises(ArgumentError, /comment marker/) { GaOrder.group("status -- x") }
    expect_raises(ArgumentError, /unbalanced/) { GaOrder.group("lower(status") }
    expect_raises(ArgumentError, /unterminated quote/) { GaOrder.group("'open") }
    expect_raises(ArgumentError, /blank/) { GaOrder.group(" ") }
  end
end
