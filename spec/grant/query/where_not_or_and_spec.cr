require "../../spec_helper"
require "../../support/where_family_models"

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map { |post| post.title.to_s }
end

describe "where.not, and relation or / and" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    WfPost.create!(title: "a", published: true, score: 1)
    WfPost.create!(title: "b", published: false, score: 2)
    WfPost.create!(title: "c", published: true, score: 3)
    WfPost.create!(title: "d", published: true, score: nil)
  end

  describe "where.not with keywords" do
    it "negates several keys together (NAND)" do
      relation = WfPost.where.not(published: true, score: 1)
      relation.to_sql.should contain("NOT (")
      titles(relation).should eq(["b", "c"])
    end

    it "negates one key" do
      titles(WfPost.where.not(published: false)).should eq(["a", "c", "d"])
      titles(WfPost.where.not(title: "a")).should eq(["b", "c", "d"])
    end

    it "turns an array into NOT IN" do
      titles(WfPost.where.not(title: ["a", "b"])).should eq(["c", "d"])
      titles(WfPost.where.not(title: [] of String)).should eq(["a", "b", "c", "d"])
    end

    it "turns nil into IS NOT NULL" do
      titles(WfPost.where.not(score: nil)).should eq(["a", "b", "c"])
    end

    it "negates a range, open ranges included" do
      titles(WfPost.where.not(score: 2..3)).should eq(["a"])
      titles(WfPost.where.not(score: 2...3)).should eq(["a", "c"])
      titles(WfPost.where.not(score: ..1)).should eq(["b", "c"])
      titles(WfPost.where.not(score: 3..)).should eq(["a", "b"])
    end

    it "treats a NULL column as unmatched on both sides, like SQL" do
      titles(WfPost.where(score: 1..3)).should eq(["a", "b", "c"])
      titles(WfPost.where.not(score: 1..3)).should eq([] of String)
    end

    it "keeps the scalar two-argument form" do
      titles(WfPost.where.not(:title, "a")).should eq(["b", "c", "d"])
    end

    it "combines with other conditions and binds in order" do
      relation = WfPost.where(published: true).where.not(title: ["a", "b"], score: 3).where(title: "c")
      titles(relation).should eq(["c"])
      relation = WfPost.where(published: true).where.not(title: ["a"], score: 1).where(score: 1..3)
      titles(relation).should eq(["c"])
      relation = WfPost.where(published: true).where.not(title: "d", score: 3).where(score: 1..3)
      titles(relation).should eq(["a", "c"])
    end

    it "rejects an unknown column" do
      expect_raises(ArgumentError) { WfPost.where.not(nonsense: 1).to_sql }
    end

    it "leaves the receiver untouched" do
      base = WfPost.where(published: true)
      base.where.not(score: 1)
      titles(base).should eq(["a", "c", "d"])
    end
  end

  describe "or with a relation" do
    it "ORs the two relations' conditions" do
      relation = WfPost.where(title: "a").or(WfPost.where(title: "c"))
      titles(relation).should eq(["a", "c"])
      relation.to_sql.should contain("OR")
    end

    it "parenthesizes each side" do
      relation = WfPost.where(published: true, score: 1).or(WfPost.where(published: false, score: 2))
      titles(relation).should eq(["a", "b"])
      relation = WfPost.where(published: true, score: 3).or(WfPost.where(title: "b"))
      titles(relation).should eq(["b", "c"])
    end

    it "keeps a condition ANDed afterwards outside the OR" do
      relation = WfPost.where(title: "a").or(WfPost.where(title: "b")).where(published: true)
      titles(relation).should eq(["a"])
    end

    it "keeps bind order across the OR (numbered on PG)" do
      relation = WfPost.where(title: "a", score: 1).or(WfPost.where(title: ["b", "c"], published: false)).where(score: 1..2)
      titles(relation).should eq(["a", "b"])
      relation = WfPost.where("score = :x", x: 1).or(WfPost.where("score = :y AND title = :z", y: 3, z: "c"))
      titles(relation).should eq(["a", "c"])
    end

    it "chains" do
      relation = WfPost.where(title: "a").or(WfPost.where(title: "b")).or(WfPost.where(title: "d"))
      titles(relation).should eq(["a", "b", "d"])
    end

    it "is unconstrained when either side has no conditions" do
      titles(WfPost.where(title: "a").or(WfPost.all)).size.should eq(4)
      titles(WfPost.all.or(WfPost.where(title: "a"))).size.should eq(4)
    end

    it "accepts relations built from the same joins, ordering and limit" do
      left = WfPost.joins(:author).where(title: "a").order(:id).limit(3)
      right = WfPost.joins(:author).where(title: "b").order(:id).limit(3)
      left.or(right).to_sql.should contain("OR")
    end

    it "raises ArgumentError naming what differs" do
      expect_raises(ArgumentError, /structurally compatible.*\[:joins\]/) do
        WfPost.where(title: "a").or(WfPost.joins(:author).where(title: "b"))
      end
      expect_raises(ArgumentError, /\[:limit\]/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").limit(1))
      end
      expect_raises(ArgumentError, /:order/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").order(:id))
      end
      expect_raises(ArgumentError, /:offset/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").offset(1))
      end
      expect_raises(ArgumentError, /:distinct/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").distinct)
      end
      expect_raises(ArgumentError, /:group/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").group_by(:title))
      end
      expect_raises(ArgumentError, /:includes/) do
        WfPost.where(title: "a").or(WfPost.where(title: "b").includes(:author))
      end
    end

    it "leaves both relations untouched" do
      left = WfPost.where(title: "a")
      right = WfPost.where(title: "b")
      left.or(right)
      titles(left).should eq(["a"])
      titles(right).should eq(["b"])
    end

    it "still supports the keyword, string and block forms" do
      titles(WfPost.where(title: "a").or(title: "b")).should eq(["a", "b"])
      titles(WfPost.where(title: "a").or("title = ?", "c")).should eq(["a", "c"])
      titles(WfPost.where(title: "a").or { |q| q.where(title: "d") }).should eq(["a", "d"])
    end
  end

  describe "and with a relation" do
    it "ANDs the two relations' conditions" do
      relation = WfPost.where(published: true).and(WfPost.where(score: 1..2))
      titles(relation).should eq(["a"])
    end

    it "keeps both conditions on the same column" do
      relation = WfPost.where(score: 1..3).and(WfPost.where(score: 2..4))
      titles(relation).should eq(["b", "c"])
    end

    it "groups an OR on the other side" do
      other = WfPost.where(title: "a").or(WfPost.where(title: "b"))
      titles(WfPost.where(published: true).and(other)).should eq(["a"])
    end

    it "groups an OR on the receiver" do
      receiver = WfPost.where(title: "a").or(WfPost.where(title: "b"))
      titles(receiver.and(WfPost.where(published: false))).should eq(["b"])
    end

    it "does nothing for an empty relation" do
      titles(WfPost.where(title: "a").and(WfPost.all)).should eq(["a"])
    end

    it "raises ArgumentError for incompatible relations" do
      expect_raises(ArgumentError, /structurally compatible.*\[:joins\]/) do
        WfPost.where(title: "a").and(WfPost.joins(:author).where(title: "b"))
      end
      expect_raises(ArgumentError, /\[:limit\]/) do
        WfPost.where(title: "a").and(WfPost.where(title: "b").limit(2))
      end
    end

    it "keeps the keyword and string forms" do
      titles(WfPost.where(published: true).and(score: 3)).should eq(["c"])
      titles(WfPost.where(published: true).and("score = ?", 1)).should eq(["a"])
    end
  end
end
