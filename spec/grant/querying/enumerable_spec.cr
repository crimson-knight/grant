require "../../spec_helper"

# Tests for Issue #36: Query::Builder should include Enumerable(T)
#
# These tests validate that Grant::Query::Builder(T) properly supports
# standard Crystal collection methods through Enumerable(T) inclusion.
# All methods should work directly on query builder results without
# requiring an intermediate .all call.
#
# BEFORE THE FIX: These tests will fail to compile.
# AFTER THE FIX: All tests should pass.
describe "Grant::Query::Builder Enumerable support" do
  before_each do
    Parent.clear

    Parent.create(name: "alice")
    Parent.create(name: "bob")
    Parent.create(name: "carol")
    Parent.create(name: "dave")
    Parent.create(name: "eve")
  end

  describe "#each with block" do
    it "iterates over all matching records directly on the query builder" do
      names = [] of String?
      Parent.where(name: ["alice", "bob", "carol"]).each do |record|
        names << record.name
      end
      names.size.should eq 3
      names.should contain("alice")
      names.should contain("bob")
      names.should contain("carol")
    end

    it "works on a filtered query" do
      count = 0
      Parent.where(name: "alice").each { |_| count += 1 }
      count.should eq 1
    end
  end

  describe "#map with block" do
    it "transforms records using a block directly on the query builder" do
      names = Parent.where(name: ["alice", "bob"]).map { |r| r.name }
      names.size.should eq 2
      names.should contain("alice")
      names.should contain("bob")
    end

    it "maps to different types" do
      ids = Parent.where(name: ["alice", "bob"]).map { |r| r.id }
      ids.size.should eq 2
      ids.each { |id| id.should_not be_nil }
    end
  end

  describe "#select with block (in-memory filter from Enumerable)" do
    it "filters records in-memory using a block" do
      results = Parent.where(name: ["alice", "bob", "carol"]).select { |r|
        name = r.name
        name ? name.starts_with?("a") || name.starts_with?("c") : false
      }
      results.size.should eq 2
      results.map(&.name).should contain("alice")
      results.map(&.name).should contain("carol")
    end

    it "works alongside SQL where clauses" do
      results = Parent.where(name: ["alice", "bob", "carol"]).select { |r|
        r.name == "bob"
      }
      results.size.should eq 1
      results.first.name.should eq "bob"
    end
  end

  describe "#select without block (SQL execution)" do
    it "still works as SQL execution when called without a block" do
      results = Parent.where(name: ["alice", "bob"]).select
      results.size.should eq 2
    end

    it "still works for column projection with symbol arguments" do
      builder = Parent.where(name: "alice").select(:name)
      builder.should be_a(Grant::Query::Builder(Parent))
    end
  end

  describe "#reject with block" do
    it "filters out records matching the block condition" do
      results = Parent.where(name: ["alice", "bob", "carol"]).reject { |r|
        r.name == "carol"
      }
      results.size.should eq 2
      results.map(&.name).should_not contain("carol")
    end
  end

  describe "#count with block" do
    it "counts records matching a block condition" do
      count = Parent.where(name: ["alice", "bob", "carol"]).count { |r|
        name = r.name
        name ? name.starts_with?("a") : false
      }
      count.should eq 1
    end

    it "returns 0 when no records match the block" do
      count = Parent.where(name: ["alice", "bob"]).count { |r|
        r.name == "nonexistent"
      }
      count.should eq 0
    end
  end

  describe "#count without block (SQL COUNT)" do
    it "still executes SQL COUNT when called without a block" do
      count = Parent.where(name: ["alice", "bob"]).count
      count.should eq 2
    end
  end

  describe "#any? with block" do
    it "returns true when at least one record matches the block" do
      result = Parent.where(name: ["alice", "bob", "carol"]).any? { |r|
        r.name == "carol"
      }
      result.should be_true
    end

    it "returns false when no records match the block" do
      result = Parent.where(name: ["alice", "bob"]).any? { |r|
        r.name == "nonexistent"
      }
      result.should be_false
    end
  end

  describe "#any? without block" do
    it "still works as existence check without a block" do
      Parent.where(name: "alice").any?.should be_true
      Parent.where(name: "nonexistent").any?.should be_false
    end
  end

  describe "#none? with block" do
    it "returns true when no records match the block" do
      result = Parent.where(name: ["alice", "bob"]).none? { |r|
        r.name == "carol"
      }
      result.should be_true
    end

    it "returns false when at least one record matches" do
      result = Parent.where(name: ["alice", "bob"]).none? { |r|
        r.name == "alice"
      }
      result.should be_false
    end
  end

  describe "#all? with block" do
    it "returns true when all records match the block" do
      result = Parent.where(name: ["alice", "bob"]).all? { |r|
        name = r.name
        !name.nil? && name.size > 0
      }
      result.should be_true
    end

    it "returns false when not all records match" do
      result = Parent.where(name: ["alice", "bob"]).all? { |r|
        r.name == "alice"
      }
      result.should be_false
    end
  end

  describe "#compact_map" do
    it "maps and removes nil values" do
      results = Parent.where(name: ["alice", "bob", "carol"]).compact_map { |r|
        name = r.name
        (name && name.starts_with?("a")) ? name.upcase : nil
      }
      results.size.should eq 1
      results.first.should eq "ALICE"
    end
  end

  describe "#flat_map" do
    it "maps and flattens the results" do
      results = Parent.where(name: ["alice", "bob"]).flat_map { |r|
        [r.name, r.name.to_s.upcase]
      }
      # 2 records * 2 elements each = 4 elements
      results.size.should eq 4
    end
  end

  describe "#min_by" do
    it "finds the record with the minimum value" do
      result = Parent.where(name: ["alice", "bob", "carol"]).min_by { |r| r.name || "" }
      result.name.should eq "alice"
    end
  end

  describe "#max_by" do
    it "finds the record with the maximum value" do
      result = Parent.where(name: ["alice", "bob", "carol"]).max_by { |r| r.name || "" }
      result.name.should eq "carol"
    end
  end

  describe "#sort_by (via to_a)" do
    it "sorts records by the given block after converting to array" do
      results = Parent.where(name: ["carol", "alice", "bob"]).to_a.sort_by { |r| r.name || "" }
      results.map(&.name).should eq ["alice", "bob", "carol"]
    end
  end

  describe "#group_by (Enumerable, with block)" do
    it "groups records by a block into a hash" do
      groups = Parent.where(name: ["alice", "bob", "carol"]).group_by { |r|
        name = r.name
        (name && name.starts_with?("a")) ? "a_names" : "other"
      }
      groups["a_names"].size.should eq 1
      groups["other"].size.should eq 2
    end
  end

  describe "#partition" do
    it "splits records into two arrays based on a block" do
      a_names, others = Parent.where(name: ["alice", "bob", "carol"]).partition { |r|
        name = r.name
        name ? name.starts_with?("a") : false
      }
      a_names.size.should eq 1
      a_names.first.name.should eq "alice"
      others.size.should eq 2
    end
  end

  describe "#reduce" do
    it "reduces records to a single value" do
      combined = Parent.where(name: ["alice", "bob"]).reduce("names:") { |acc, r|
        "#{acc} #{r.name}"
      }
      combined.should contain("alice")
      combined.should contain("bob")
    end
  end

  describe "#each_with_object" do
    it "iterates with an accumulator object" do
      result = Parent.where(name: ["alice", "bob", "carol"]).each_with_object([] of String) { |r, arr|
        arr << (r.name || "unknown").upcase
      }
      result.size.should eq 3
      result.should contain("ALICE")
      result.should contain("BOB")
      result.should contain("CAROL")
    end
  end

  describe "#sum with block" do
    it "sums values returned by the block" do
      total = Parent.where(name: ["alice", "bob", "carol"]).sum { |r| (r.name || "").size }
      # "alice"=5 + "bob"=3 + "carol"=5 = 13
      total.should eq 13
    end
  end

  describe "#to_a" do
    it "converts query results to an array" do
      results = Parent.where(name: ["alice", "bob"]).to_a
      results.should be_a(Array(Parent))
      results.size.should eq 2
    end
  end

  describe "#size returns numeric type" do
    it "returns an integer value usable in arithmetic" do
      size = Parent.where(name: ["alice", "bob", "carol"]).size
      (size == 3).should be_true
      (size > 0).should be_true
      (size < 100).should be_true
    end

    it "can be passed to methods expecting numeric types" do
      size = Parent.where(name: ["alice", "bob"]).size
      # Should be usable as an Int without unwrapping an executor
      result = size + 1
      result.should eq 3
    end
  end

  describe "#includes_enumerable? (type check)" do
    it "Builder includes Enumerable" do
      builder = Parent.where(name: "alice")
      builder.should be_a(Enumerable(Parent))
    end
  end

  describe "chaining with other query methods" do
    it "works with order + each" do
      names = [] of String?
      Parent.where(name: ["carol", "alice", "bob"]).order(name: :asc).each { |r| names << r.name }
      names.should eq ["alice", "bob", "carol"]
    end

    it "works with limit + map" do
      results = Parent.where(name: ["alice", "bob", "carol"]).order(name: :asc).limit(2).map { |r| r.name }
      results.size.should eq 2
      results.should eq ["alice", "bob"]
    end

    it "works with offset + to_a" do
      results = Parent.where(name: ["alice", "bob", "carol"]).order(name: :asc).offset(1).limit(2).to_a
      results.size.should eq 2
    end

    it "works with select (filter) after order" do
      results = Parent.where(name: ["alice", "bob", "carol"]).order(name: :asc).select { |r|
        r.name != "bob"
      }
      results.size.should eq 2
      results.map(&.name).should eq ["alice", "carol"]
    end
  end
end
