require "../../spec_helper"
require "../../support/relation_sql_capture"

private def seed_parents(names : Array(String)) : Array(Parent)
  Parent.clear
  names.map { |name| Parent.create(name: name) }
end

describe "Existence predicates" do
  describe "with no matching rows" do
    it "answers false/true without loading anything" do
      seed_parents(["a"])
      relation = Parent.where(name: "nope")

      relation.empty?.should be_true
      relation.none?.should be_true
      relation.any?.should be_false
      relation.many?.should be_false
      relation.one?.should be_false
    end
  end

  describe "with one matching row" do
    it "answers one? but not many?" do
      seed_parents(["a", "b"])
      relation = Parent.where(name: "a")

      relation.empty?.should be_false
      relation.none?.should be_false
      relation.any?.should be_true
      relation.many?.should be_false
      relation.one?.should be_true
    end
  end

  describe "with several matching rows" do
    it "answers many? but not one?" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      relation.empty?.should be_false
      relation.none?.should be_false
      relation.any?.should be_true
      relation.many?.should be_true
      relation.one?.should be_false
    end
  end

  describe "SQL issued" do
    it "uses LIMIT 1 for empty?, any? and none?" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      [
        capture_sql { relation.empty? },
        capture_sql { relation.any? },
        capture_sql { relation.none? },
      ].each do |statements|
        statements.size.should eq 1
        statements.first.should contain("LIMIT 1")
        statements.first.should_not contain("LIMIT 2")
        statements.first.should_not contain("ORDER BY")
        statements.first.should_not contain("created_at")
      end
    end

    it "uses LIMIT 2 for many? and one?" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      [
        capture_sql { relation.many? },
        capture_sql { relation.one? },
      ].each do |statements|
        statements.size.should eq 1
        statements.first.should contain("LIMIT 2")
        statements.first.should_not contain("ORDER BY")
        statements.first.should_not contain("created_at")
      end
    end

    it "uses LIMIT 2 for sole and never loads more than two rows" do
      seed_parents(["a", "b", "c"])

      statements = capture_sql do
        expect_raises(Grant::Querying::NotUnique) { Parent.where("name != ?", "zzz").sole }
      end

      statements.size.should eq 1
      statements.first.should contain("LIMIT 2")
      Parent.where(name: "a").sole.name.should eq "a"
      expect_raises(Grant::Querying::NotFound) { Parent.where(name: "nope").sole }
    end

    it "does not hydrate the full relation to answer emptiness" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      capture_sql { relation.empty?; relation.many? }.each do |sql|
        sql.should_not contain("name, created_at")
      end
      relation.loaded?.should be_false
    end
  end

  describe "with relation limits and offsets" do
    it "respects an existing limit" do
      seed_parents(["a", "b", "c"])

      Parent.where("name != ?", "zzz").limit(1).many?.should be_false
      Parent.where("name != ?", "zzz").limit(1).one?.should be_true
      Parent.where("name != ?", "zzz").limit(2).many?.should be_true
    end

    it "respects an existing offset" do
      seed_parents(["a", "b", "c"])

      Parent.where("name != ?", "zzz").offset(2).one?.should be_true
      Parent.where("name != ?", "zzz").offset(2).many?.should be_false
      Parent.where("name != ?", "zzz").offset(3).empty?.should be_true
      Parent.where("name != ?", "zzz").offset(1).many?.should be_true
    end
  end

  describe "none relations" do
    it "answer without SQL" do
      seed_parents(["a", "b"])
      relation = Parent.where("name != ?", "zzz").none

      capture_sql do
        relation.empty?.should be_true
        relation.any?.should be_false
        relation.none?.should be_true
        relation.many?.should be_false
        relation.one?.should be_false
      end.should be_empty
    end
  end

  describe "block forms" do
    it "fall back to Enumerable" do
      seed_parents(["a", "b", "c"])
      relation = Parent.where("name != ?", "zzz")

      relation.any? { |parent| parent.name == "a" }.should be_true
      relation.any? { |parent| parent.name == "q" }.should be_false
      relation.none? { |parent| parent.name == "q" }.should be_true
      relation.one? { |parent| parent.name == "a" }.should be_true
      relation.one? { |parent| parent.name != "a" }.should be_false
      relation.many? { |parent| parent.name != "a" }.should be_true
      relation.many? { |parent| parent.name == "a" }.should be_false
    end
  end

  describe "the receiver" do
    it "stays unchanged and unloaded" do
      seed_parents(["a", "b"])
      relation = Parent.where("name != ?", "zzz")
      sql = relation.to_sql

      relation.empty?
      relation.any?
      relation.many?
      relation.one?
      relation.none?

      relation.to_sql.should eq sql
      relation.limit.should be_nil
      relation.loaded?.should be_false
    end
  end
end
