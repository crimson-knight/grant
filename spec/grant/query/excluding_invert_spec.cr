require "../../spec_helper"
require "../../support/where_family_models"

class WfRegionLine < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{(env("CURRENT_ADAPTER") || "sqlite").id}}
  table wf_region_lines

  column region_id : Int64, primary: true
  column line_id : Int64, primary: true
  column label : String?

  composite_primary_key region_id, line_id
end

private def seed_region_lines : Nil
  WfRegionLine.adapter.open do |db|
    db.exec "DROP TABLE IF EXISTS wf_region_lines"
    db.exec "CREATE TABLE wf_region_lines (region_id BIGINT NOT NULL, line_id BIGINT NOT NULL, label VARCHAR(20), PRIMARY KEY (region_id, line_id))"
    [{1, 1, "r1l1"}, {1, 2, "r1l2"}, {2, 1, "r2l1"}].each do |region, line, label|
      db.exec "INSERT INTO wf_region_lines (region_id, line_id, label) VALUES (#{region}, #{line}, '#{label}')"
    end
  end
end

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map { |post| post.title.to_s }
end

describe "excluding, without and invert_where" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    WfPost.create!(title: "a", published: true, score: 1)
    WfPost.create!(title: "b", published: false, score: 2)
    WfPost.create!(title: "c", published: true, score: 3)
    WfPost.create!(title: "d", published: true, score: nil)
  end

  describe "excluding" do
    it "leaves out the given records" do
      a = WfPost.find_by!(title: "a")
      c = WfPost.find_by!(title: "c")
      titles(WfPost.excluding(a, c)).should eq(["b", "d"])
      titles(WfPost.excluding(a)).should eq(["b", "c", "d"])
    end

    it "takes an array and a relation's records" do
      records = WfPost.where(published: true).order(:id).select
      titles(WfPost.excluding(records)).should eq(["b"])
      titles(WfPost.excluding(records.to_a)).should eq(["b"])
    end

    it "chains onto a relation" do
      a = WfPost.find_by!(title: "a")
      titles(WfPost.where(score: 1..3).excluding(a)).should eq(["b", "c"])
      titles(WfPost.excluding(a).where(score: 1..3)).should eq(["b", "c"])
    end

    it "is a no-op for no records" do
      titles(WfPost.excluding([] of WfPost)).should eq(["a", "b", "c", "d"])
      WfPost.excluding([] of WfPost).to_sql.should_not contain("NOT IN")
    end

    it "ignores records that were never saved" do
      a = WfPost.find_by!(title: "a")
      titles(WfPost.excluding(a, WfPost.new(title: "new"))).should eq(["b", "c", "d"])
      titles(WfPost.excluding(WfPost.new(title: "new"))).should eq(["a", "b", "c", "d"])
    end

    it "uses NOT IN on the primary key" do
      a = WfPost.find_by!(title: "a")
      b = WfPost.find_by!(title: "b")
      WfPost.excluding(a, b).to_sql.should contain("NOT IN")
    end

    it "excludes each key combination of a composite primary key" do
      seed_region_lines
      r1l2 = WfRegionLine.where(region_id: 1_i64, line_id: 2_i64).first!
      r2l1 = WfRegionLine.where(region_id: 2_i64, line_id: 1_i64).first!
      labels = WfRegionLine.excluding(r1l2, r2l1).order([:region_id, :line_id]).select.map(&.label)
      labels.should eq(["r1l1"])
      WfRegionLine.excluding(r1l2).to_sql.should contain("NOT (")
    end

    it "spells without the same way" do
      a = WfPost.find_by!(title: "a")
      b = WfPost.find_by!(title: "b")
      titles(WfPost.without(a, b)).should eq(["c", "d"])
      titles(WfPost.where(score: 1..3).without([a])).should eq(["b", "c"])
    end

    it "does not change the receiver" do
      a = WfPost.find_by!(title: "a")
      base = WfPost.where(score: 1..3)
      base.excluding(a)
      titles(base).should eq(["a", "b", "c"])
    end
  end

  describe "invert_where" do
    it "negates all the conditions together" do
      relation = WfPost.where(published: true, score: 1).invert_where
      relation.to_sql.should contain("NOT (")
      titles(relation).should eq(["b", "c"])
    end

    it "negates a single condition" do
      titles(WfPost.where(score: 1..2).invert_where).should eq(["c"])
      titles(WfPost.where(title: ["a", "b"]).invert_where).should eq(["c", "d"])
    end

    it "does nothing without conditions" do
      titles(WfPost.all.invert_where).should eq(["a", "b", "c", "d"])
      WfPost.all.invert_where.to_sql.should_not contain("NOT")
    end

    it "only inverts what came before it" do
      titles(WfPost.where(published: true).invert_where.where(score: 2..4)).should eq(["b"])
    end

    it "follows SQL NULL logic like ActiveRecord: a NULL column matches neither side" do
      titles(WfPost.where(published: true, score: 1..3)).should eq(["a", "c"])
      titles(WfPost.where(published: true, score: 1..3).invert_where).should eq(["b"])
      titles(WfPost.where(score: nil).invert_where).should eq(["a", "b", "c"])
    end

    it "inverts an or chain as one group" do
      relation = WfPost.where(title: "a").or(title: "b").invert_where
      titles(relation).should eq(["c", "d"])
    end

    it "keeps bind order after the group (numbered on PG)" do
      relation = WfPost.where(score: 1, title: "a").invert_where.where(title: "b").where(score: 2)
      titles(relation).should eq(["b"])
    end

    it "does not change the receiver" do
      base = WfPost.where(published: false)
      base.invert_where
      titles(base).should eq(["b"])
    end
  end
end
