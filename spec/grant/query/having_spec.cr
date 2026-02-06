require "./spec_helper"

describe "Grant::Query::Builder - Having" do
  describe "#having" do
    it "stores having clauses" do
      query = builder.having("COUNT(*) > ?", 5)
      query.having_clauses.size.should eq 1
      query.having_clauses.first[:stmt].should eq "COUNT(*) > ?"
      query.having_clauses.first[:value].should eq 5
    end

    it "supports having without a value" do
      query = builder.having("COUNT(*) > 0")
      query.having_clauses.size.should eq 1
      query.having_clauses.first[:value].should be_nil
    end

    it "chains multiple having clauses" do
      query = builder
        .group_by(:name)
        .having("COUNT(*) > ?", 5)
        .having("SUM(age) > ?", 100)
      query.having_clauses.size.should eq 2
    end

    it "works with joins and group_by" do
      query = builder
        .joins("posts", on: "posts.user_id = table.id")
        .group_by(:name)
        .having("COUNT(*) > ?", 3)
      query.join_clauses.size.should eq 1
      query.group_fields.size.should eq 1
      query.having_clauses.size.should eq 1
    end

    it "returns self for chaining" do
      query = builder.having("COUNT(*) > ?", 5)
      query.should be_a Grant::Query::Builder(Model)
    end
  end

  describe "dup preserves having" do
    it "copies having clauses on dup" do
      original = builder.having("COUNT(*) > ?", 5)
      copy = original.dup
      copy.having_clauses.size.should eq 1
      copy.having_clauses.first[:stmt].should eq "COUNT(*) > ?"
    end

    it "dup creates independent copy" do
      original = builder.having("COUNT(*) > ?", 5)
      copy = original.dup
      copy.having("SUM(age) > ?", 100)
      original.having_clauses.size.should eq 1
      copy.having_clauses.size.should eq 2
    end
  end

  describe "merge preserves having" do
    it "merges having clauses from another builder" do
      b1 = builder.having("COUNT(*) > ?", 5)
      b2 = builder.having("SUM(age) > ?", 100)
      b1.merge(b2)
      b1.having_clauses.size.should eq 2
    end
  end
end
