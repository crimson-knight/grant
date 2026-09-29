require "../../spec_helper"
require "../../support/where_family_models"

private def rank_labels(relation : Grant::Query::Builder(WfMeasure)) : Array(String)
  relation.order(:rank).select.map { |measure| measure.label.to_s }
end

describe "where with a Range" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    (1..5).each do |rank|
      WfMeasure.create!(
        label: "m#{rank}",
        rank: rank,
        amount: rank * 1.5,
        happened_at: Time.utc(2024, rank, 1)
      )
    end
  end

  it "keeps closed and exclusive-end ranges" do
    rank_labels(WfMeasure.where(rank: 2..4)).should eq(["m2", "m3", "m4"])
    rank_labels(WfMeasure.where(rank: 2...4)).should eq(["m2", "m3"])
  end

  it "keeps only the upper bound of a beginless range" do
    rank_labels(WfMeasure.where(rank: ..3)).should eq(["m1", "m2", "m3"])
    rank_labels(WfMeasure.where(rank: ...3)).should eq(["m1", "m2"])
    WfMeasure.where(rank: ..3).to_sql.should contain("<=")
    WfMeasure.where(rank: ...3).to_sql.should contain("<")
  end

  it "keeps only the lower bound of an endless range" do
    rank_labels(WfMeasure.where(rank: 4..)).should eq(["m4", "m5"])
    rank_labels(WfMeasure.where(rank: 4...)).should eq(["m4", "m5"])
    WfMeasure.where(rank: 4..).to_sql.should_not contain("<")
  end

  it "adds no condition for a range with neither bound" do
    WfMeasure.where(rank: (nil..nil)).count.should eq(5)
  end

  it "supports Float ranges" do
    rank_labels(WfMeasure.where(amount: 3.0..6.0)).should eq(["m2", "m3", "m4"])
    rank_labels(WfMeasure.where(amount: ..3.0)).should eq(["m1", "m2"])
    rank_labels(WfMeasure.where(amount: 6.0..)).should eq(["m4", "m5"])
  end

  it "supports Time ranges" do
    span = Time.utc(2024, 2, 1)..Time.utc(2024, 4, 1)
    rank_labels(WfMeasure.where(happened_at: span)).should eq(["m2", "m3", "m4"])
    rank_labels(WfMeasure.where(happened_at: Time.utc(2024, 2, 1)...Time.utc(2024, 4, 1))).should eq(["m2", "m3"])
    rank_labels(WfMeasure.where(happened_at: ..Time.utc(2024, 2, 1))).should eq(["m1", "m2"])
    rank_labels(WfMeasure.where(happened_at: Time.utc(2024, 5, 1)..)).should eq(["m5"])
  end

  it "supports String ranges" do
    rank_labels(WfMeasure.where(label: "m2".."m4")).should eq(["m2", "m3", "m4"])
    rank_labels(WfMeasure.where(label: "m3"..)).should eq(["m3", "m4", "m5"])
    rank_labels(WfMeasure.where(label: ..."m3")).should eq(["m1", "m2"])
  end

  it "combines with other conditions and with and" do
    rank_labels(WfMeasure.where(rank: 2..).where(amount: ..6.0)).should eq(["m2", "m3", "m4"])
    rank_labels(WfMeasure.where(rank: 1..).and(rank: ..2)).should eq(["m1", "m2"])
  end

  it "groups an open range under or" do
    rank_labels(WfMeasure.where(label: "m1").or(rank: 5..)).should eq(["m1", "m5"])
    rank_labels(WfMeasure.where(label: "m1").or(rank: ..2)).should eq(["m1", "m2"])
    rank_labels(WfMeasure.where(label: "m1").or(rank: 4...5)).should eq(["m1", "m4"])
  end

  it "binds the range values in order" do
    relation = WfMeasure.where(label: "m3").or(rank: 4..5).where(amount: ..100.0)
    rank_labels(relation).should eq(["m3", "m4", "m5"])
  end

  it "applies to where.between" do
    rank_labels(WfMeasure.where.between(:rank, 2..3)).should eq(["m2", "m3"])
  end
end
