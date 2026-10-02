require "../../spec_helper"

class W6roRow < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6ro_rows

  column id : Int64, primary: true
  column name : String?
  column kind : String?
  column rank : Int32 = 0
  column seq : Int32 = 0
end

private def seqs(relation : Grant::Query::Builder(W6roRow)) : Array(Int32)
  relation.select.map(&.seq)
end

describe "reorder, reselect and regroup raw-SQL forms" do
  before_all { W6roRow.migrator.drop_and_create }
  before_each do
    W6roRow.clear
    W6roRow.create!(name: "b", kind: "x", rank: 1, seq: 1)
    W6roRow.create!(name: "a", kind: "x", rank: 2, seq: 2)
    W6roRow.create!(name: "c", kind: "y", rank: 3, seq: 3)
    W6roRow.create!(name: "a", kind: "y", rank: 4, seq: 4)
  end

  describe "reorder(String)" do
    it "replaces the order with parsed SQL terms" do
      relation = W6roRow.order(:name).reorder("rank DESC")
      relation.order_fields.map { |term| term[:field] }.should eq(["rank"])
      seqs(relation).should eq([4, 3, 2, 1])
    end

    it "takes several terms and directions" do
      seqs(W6roRow.order(:seq).reorder("name ASC, rank DESC")).should eq([4, 2, 1, 3])
    end

    it "accepts a function of columns and a trusted expression" do
      seqs(W6roRow.reorder("lower(name) DESC, seq")).should eq([3, 1, 2, 4])
      seqs(W6roRow.order(:name).reorder(Grant.sql("CASE WHEN kind = 'y' THEN 0 ELSE 1 END, seq"))).should eq([3, 4, 1, 2])
    end

    it "rejects SQL that is not a column or function of columns, like order" do
      expect_raises(ArgumentError) { W6roRow.reorder("rank; DROP TABLE w6ro_rows") }
      expect_raises(ArgumentError) { W6roRow.reorder("(SELECT 1)") }
    end

    it "takes a direction and a NULL placement" do
      seqs(W6roRow.order(:name).reorder(:rank, :desc)).should eq([4, 3, 2, 1])
      # rank is reserved on MySQL, so Grant quotes it on every adapter.
      W6roRow.order(:name).reorder("rank", :desc).to_sql.should contain("ORDER BY #{W6roRow.quote("rank")} DESC")
      W6roRow.order(:name).reorder(:rank, nulls: :last).order_fields.size.should eq(1)
    end

    it "works at the class level, in place of the model's order" do
      seqs(W6roRow.reorder("seq DESC")).should eq([4, 3, 2, 1])
    end

    it "marks the relation as reordered and keeps the receiver intact" do
      base = W6roRow.order(:name)
      reordered = base.reorder("rank")
      reordered.reordering?.should be_true
      base.reordering?.should be_false
      base.order_fields.map { |term| term[:field] }.should eq(["name"])
    end

    it "reverse_order flips the reordered terms" do
      seqs(W6roRow.order(:name).reorder("rank DESC").reverse_order).should eq([1, 2, 3, 4])
    end
  end

  describe "reselect" do
    it "replaces the projection with strings, arrays and mixes" do
      W6roRow.select(:id).reselect("name", "kind").to_sql.should contain("SELECT name, kind FROM")
      W6roRow.select(:id).reselect(["name", :kind]).to_sql.should contain("SELECT name, kind FROM")
      W6roRow.select(:id).reselect(:name, "kind").to_sql.should contain("SELECT name, kind FROM")
    end

    it "loads the reselected columns, expressions included" do
      row = W6roRow.select(:id).reselect(:name, "seq * 10 AS scaled").where(seq: 2).first!
      row.name.should eq("a")
      row.extra_attribute("scaled").to_s.to_i.should eq(20)
    end

    it "validates string expressions" do
      expect_raises(ArgumentError) { W6roRow.reselect("name; DROP TABLE w6ro_rows") }
    end
  end

  describe "regroup" do
    it "replaces the grouping with strings, arrays and mixes" do
      W6roRow.group(:kind).regroup("lower(name)").to_sql.should contain("GROUP BY lower(name)")
      W6roRow.group(:kind).regroup(["name", :kind]).to_sql.should contain("GROUP BY name, kind")
      W6roRow.group(:kind).regroup(:name, "kind").to_sql.should contain("GROUP BY name, kind")
      W6roRow.group(:kind).regroup(:name).to_sql.should_not contain("kind\"")
    end

    it "groups by the new expression when counting" do
      counts = W6roRow.group(:kind).regroup(:name).count
      counts.should be_a(Hash(Grant::Columns::Type, Int64))
      counts.as(Hash(Grant::Columns::Type, Int64))["a"].should eq(2)
    end

    it "leaves the receiver untouched" do
      base = W6roRow.group(:kind)
      base.regroup(:name)
      base.group_fields.map { |field| field[:field] }.should eq(["kind"])
    end
  end
end
