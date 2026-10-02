require "../../spec_helper"
require "../../support/where_family_models"

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map(&.title.to_s)
end

describe "where with named binds" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    WfPost.create!(title: "a: b", published: true, score: 1)
    WfPost.create!(title: "plain", published: false, score: 2)
    WfPost.create!(title: "it's :here", published: true, score: 3)
    WfPost.create!(title: "other", published: true, score: 4)
  end

  describe "rewriting" do
    it "turns :name into ? in placeholder order" do
      sql, values = Grant::Sanitization.rewrite_named_binds("score > :min AND score < :max", {min: 1, max: 4})
      sql.should eq("score > ? AND score < ?")
      values.should eq([1, 4])
    end

    it "binds a name used twice twice" do
      sql, values = Grant::Sanitization.rewrite_named_binds("score = :n OR id = :n", {n: 3})
      sql.should eq("score = ? OR id = ?")
      values.should eq([3, 3])
    end

    it "expands a list to one placeholder per element" do
      sql, values = Grant::Sanitization.rewrite_named_binds("id IN (:ids)", {ids: [1, 2, 3]})
      sql.should eq("id IN (?, ?, ?)")
      values.should eq([1, 2, 3])
    end

    it "turns an empty list into NULL" do
      sql, values = Grant::Sanitization.rewrite_named_binds("id IN (:ids)", {ids: [] of Int32})
      sql.should eq("id IN (NULL)")
      values.should be_empty
    end

    it "skips ::casts" do
      sql, values = Grant::Sanitization.rewrite_named_binds("score::text = :s AND x::int::text = :s", {s: "3"})
      sql.should eq("score::text = ? AND x::int::text = ?")
      values.should eq(["3", "3"])
    end

    it "skips text inside quotes and comments" do
      sql, values = Grant::Sanitization.rewrite_named_binds(
        "title = ':skip' AND note = \"a :b\" AND `c :d` = :real -- and :comment\n AND /* :block */ 1 = 1",
        {real: 1}
      )
      sql.should contain("':skip'")
      sql.should contain("\"a :b\"")
      sql.should contain("`c :d`")
      sql.should contain("-- and :comment")
      sql.should contain("/* :block */")
      sql.should contain("= ?")
      values.should eq([1])
    end

    it "handles a doubled quote inside a string" do
      sql, values = Grant::Sanitization.rewrite_named_binds("title = 'it''s :x' AND id = :id", {id: 7})
      sql.should eq("title = 'it''s :x' AND id = ?")
      values.should eq([7])
    end

    it "leaves a bare colon alone" do
      sql, _ = Grant::Sanitization.rewrite_named_binds("a[1:2] = :v AND t = '12:30'", {v: 1})
      sql.should eq("a[1:2] = ? AND t = '12:30'")
    end

    it "raises for a name with no value" do
      expect_raises(ArgumentError, /Missing value for named bind :b/) do
        Grant::Sanitization.rewrite_named_binds("a = :a AND b = :b", {a: 1})
      end
    end

    it "binds nil" do
      _, values = Grant::Sanitization.rewrite_named_binds("a = :a", {a: nil})
      values.should eq([nil])
    end
  end

  describe "in a relation" do
    it "binds values by name" do
      titles(WfPost.where("score > :min AND published = :published", min: 1, published: true)).should eq(["it's :here", "other"])
    end

    it "works from the model and from a relation, and chains" do
      titles(WfPost.where("score >= :min", min: 2).where("score <= :max", max: 3)).should eq(["plain", "it's :here"])
      titles(WfPost.where(published: true).where("score >= :min", min: 3)).should eq(["it's :here", "other"])
    end

    it "keeps literal colons in strings" do
      titles(WfPost.where("title = 'a: b' AND score = :s", s: 1)).should eq(["a: b"])
      titles(WfPost.where("title = :t", t: "it's :here")).should eq(["it's :here"])
    end

    it "expands lists" do
      titles(WfPost.where("score IN (:scores)", scores: [1, 4])).should eq(["a: b", "other"])
      titles(WfPost.where("score IN (:scores)", scores: [] of Int32)).should eq([] of String)
    end

    it "keeps bind order across clauses (numbered on PG)" do
      relation = WfPost.where(published: true).where("score BETWEEN :low AND :high", low: 2, high: 4).where(title: "other")
      titles(relation).should eq(["other"])
      relation = WfPost.where("score = :a", a: 1).or(WfPost.where("score = :b", b: 4))
      titles(relation).should eq(["a: b", "other"])
    end

    it "leaves a plain string without binds untouched" do
      titles(WfPost.where("title = 'plain'")).should eq(["plain"])
      titles(WfPost.where("score > ?", 3)).should eq(["other"])
    end

    it "raises for a missing value" do
      expect_raises(ArgumentError, /Missing value/) { WfPost.where("score > :min AND score < :max", min: 1) }
    end
  end

  describe "sanitize_sql_array" do
    it "takes a hash of named binds" do
      Grant::Sanitization.sanitize_sql_array(["a = :a AND b = :b", {a: 1, b: "x"}]).should eq("a = 1 AND b = 'x'")
      Grant::Sanitization.sanitize_sql_array(["a::int = :a", {a: 1}]).should eq("a::int = 1")
    end
  end
end
