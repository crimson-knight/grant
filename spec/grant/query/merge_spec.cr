require "../../spec_helper"
require "../../support/where_family_models"

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map { |post| post.title.to_s }
end

describe "merge" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    WfPost.create!(title: "a", published: true, score: 1)
    WfPost.create!(title: "b", published: false, score: 2)
    WfPost.create!(title: "c", published: true, score: 3)
  end

  it "replaces an equality on the same column, last wins" do
    merged = WfPost.where(published: true).merge(WfPost.where(published: false))
    titles(merged).should eq(["b"])
    merged.to_sql.split("WHERE").last.scan("published").size.should eq(1)
  end

  it "replaces IN and range conditions on the column an equality names" do
    merged = WfPost.where(score: [1, 2]).where(score: 1..2).merge(WfPost.where(score: 3))
    titles(merged).should eq(["c"])
  end

  it "keeps conditions on other columns" do
    merged = WfPost.where(published: true, score: 3).merge(WfPost.where(published: false))
    titles(merged).should eq([] of String)
    merged.to_sql.should contain("score")
    titles(WfPost.where(published: true, score: 1).merge(WfPost.where(score: 3))).should eq(["c"])
  end

  it "keeps a non-equality condition on a column the other side ranges over" do
    merged = WfPost.where(score: 2).merge(WfPost.where(score: 1..2))
    titles(merged).should eq(["b"])
  end

  it "ANDs conditions on different columns" do
    titles(WfPost.where(published: true).merge(WfPost.where(score: 3))).should eq(["c"])
  end

  it "leaves the receiver and the merged relation untouched" do
    left = WfPost.where(published: true)
    right = WfPost.where(published: false)
    left.merge(right)
    titles(left).should eq(["a", "c"])
    titles(right).should eq(["b"])
  end

  it "does not corrupt an OR chain on the receiver" do
    left = WfPost.where(title: "a").or(title: "b")
    titles(left.merge(WfPost.where(published: false))).should eq(["b"])
    titles(left.merge(WfPost.where(title: "c"))).should eq([] of String)
  end

  it "groups an OR chain on the merged side" do
    right = WfPost.where(title: "a").or(title: "c")
    titles(WfPost.where(published: true).merge(right)).should eq(["a", "c"])
    titles(WfPost.where(score: 3).merge(right)).should eq(["c"])
  end

  it "takes the proc form: the block gets an empty relation to fill" do
    merged = WfPost.where(published: true).merge { |scope| scope.where(published: false) }
    titles(merged).should eq(["b"])
    titles(WfPost.where(published: true).merge { |scope| scope.where(score: 3) }).should eq(["c"])
  end

  it "takes keyword conditions" do
    titles(WfPost.where(published: true).merge(published: false)).should eq(["b"])
  end

  it "merges order, limit and select from the other relation" do
    merged = WfPost.where(published: true).merge(WfPost.order(id: :desc).limit(1).select(:id, :title))
    merged.select.map(&.title.to_s).should eq(["c"])
  end

  it "merges a named scope relation" do
    scope = WfPost.where(score: 2)
    titles(WfPost.where(published: false).merge(scope)).should eq(["b"])
  end
end
