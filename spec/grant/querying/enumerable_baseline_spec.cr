require "../../spec_helper"

# Baseline tests for Issue #36: Current Query::Builder collection behavior
#
# These tests document what CURRENTLY WORKS on Query::Builder before
# adding Enumerable(T) support. They serve as regression tests to ensure
# the fix doesn't break existing functionality.
describe "Grant::Query::Builder collection baseline (pre-Enumerable)" do
  before_each do
    Parent.clear

    Parent.new(name: "alice").tap(&.save)
    Parent.new(name: "bob").tap(&.save)
    Parent.new(name: "carol").tap(&.save)
    Parent.new(name: "dave").tap(&.save)
    Parent.new(name: "eve").tap(&.save)
  end

  describe "#each (already exists on Builder)" do
    it "iterates over query results" do
      names = [] of String?
      Parent.where(name: "alice").each do |record|
        names << record.name
      end
      names.size.should eq 1
      names.first.should eq "alice"
    end

    it "iterates over multiple results" do
      names = [] of String?
      Parent.where(name: ["alice", "bob", "carol"]).each do |record|
        names << record.name
      end
      names.size.should eq 3
    end
  end

  describe "#map (already exists on Builder)" do
    it "transforms query results" do
      names = Parent.where(name: ["alice", "bob"]).map { |r| r.name }
      names.size.should eq 2
      names.should contain("alice")
      names.should contain("bob")
    end
  end

  describe "#reject (already exists on Builder)" do
    it "filters out records matching the condition" do
      results = Parent.where(name: ["alice", "bob", "carol"]).reject { |r| r.name == "carol" }
      results.size.should eq 2
      results.map(&.name).should_not contain("carol")
    end
  end

  describe "#select without block (SQL execution)" do
    it "executes the query and returns records" do
      results = Parent.where(name: ["alice", "bob", "carol"]).select
      results.size.should eq 3
    end
  end

  describe "#all" do
    it "returns all matching records" do
      results = Parent.where(name: ["alice", "bob"]).all
      results.size.should eq 2
    end
  end

  describe "#count without block (SQL COUNT)" do
    it "returns Int64 from SQL COUNT" do
      count = Parent.where(name: ["alice", "bob", "carol"]).count
      count.should be_a(Int64)
      count.should eq 3
    end
  end

  describe "#any? without block" do
    it "returns true when records exist" do
      Parent.where(name: "alice").any?.should be_true
    end

    it "returns false when no records match" do
      Parent.where(name: "nonexistent").any?.should be_false
    end
  end

  describe "#first" do
    it "returns the first matching record" do
      result = Parent.where(name: "alice").first
      result.should_not be_nil
      result.not_nil!.name.should eq "alice"
    end
  end

  describe "#exists?" do
    it "checks for record existence via SQL" do
      Parent.where(name: "alice").exists?.should be_true
      Parent.where(name: "nonexistent").exists?.should be_false
    end
  end

  describe "chaining" do
    it "supports where + order + limit chaining" do
      results = Parent.where(name: ["alice", "bob", "carol"]).order(name: :asc).limit(2).select
      results.size.should eq 2
      results.first.name.should eq "alice"
    end
  end

  describe "#size" do
    it "returns Int64 (same as count)" do
      size = Parent.where(name: ["alice", "bob", "carol"]).size
      size.should be_a(Int64)
      size.should eq 3
    end
  end

  # Workaround pattern from Issue #36:
  # Users must currently call .all before collection methods
  describe ".all workaround pattern" do
    it "requires .all before .select with block" do
      results = Parent.where(name: ["alice", "bob", "carol"]).all.select { |r|
        r.name == "alice" || r.name == "bob"
      }
      results.size.should eq 2
    end

    it "requires .all before .count with block" do
      count = Parent.where(name: ["alice", "bob", "carol"]).all.count { |r|
        r.name == "alice"
      }
      count.should eq 1
    end

    it "requires .all before .any? with block" do
      result = Parent.where(name: ["alice", "bob", "carol"]).all.any? { |r|
        r.name == "carol"
      }
      result.should be_true
    end

    it "requires .all before .min_by" do
      result = Parent.where(name: ["alice", "bob", "carol"]).all.min_by { |r| r.name || "" }
      result.name.should eq "alice"
    end

    it "requires .all before .max_by" do
      result = Parent.where(name: ["alice", "bob", "carol"]).all.max_by { |r| r.name || "" }
      result.name.should eq "carol"
    end

    it "requires .all before .sort_by" do
      results = Parent.where(name: ["carol", "alice", "bob"]).all.sort_by { |r| r.name || "" }
      results.map(&.name).should eq ["alice", "bob", "carol"]
    end

    it "requires .all before .reduce" do
      total = Parent.where(name: ["alice", "bob", "carol"]).all.reduce("") { |acc, r| acc + (r.name || "") }
      total.should contain("alice")
      total.should contain("bob")
      total.should contain("carol")
    end

    it "requires .all before .partition" do
      a_names, others = Parent.where(name: ["alice", "bob", "carol"]).all.partition { |r|
        name = r.name
        name ? name.starts_with?("a") : false
      }
      a_names.size.should eq 1
      others.size.should eq 2
    end
  end
end
