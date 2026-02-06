require "./spec_helper"

describe "Grant::Query::Builder - Distinct" do
  describe "#distinct" do
    it "sets the distinct flag" do
      query = builder.distinct
      query.distinct?.should be_true
    end

    it "defaults to non-distinct" do
      query = builder
      query.distinct?.should be_false
    end

    it "returns self for chaining" do
      query = builder.distinct
      query.should be_a Grant::Query::Builder(Model)
    end

    it "works with where conditions" do
      query = builder.distinct.where(name: "bob")
      query.distinct?.should be_true
      query.where_fields.size.should eq 1
    end

    it "works with order" do
      query = builder.distinct.order(name: :asc)
      query.distinct?.should be_true
      query.order_fields.size.should eq 1
    end

    it "works with joins" do
      query = builder
        .distinct
        .joins("posts", on: "posts.user_id = table.id")
      query.distinct?.should be_true
      query.join_clauses.size.should eq 1
    end
  end

  describe "dup preserves distinct" do
    it "copies distinct flag on dup" do
      original = builder.distinct
      copy = original.dup
      copy.distinct?.should be_true
    end

    it "non-distinct is preserved on dup" do
      original = builder
      copy = original.dup
      copy.distinct?.should be_false
    end
  end

  describe "merge preserves distinct" do
    it "merges distinct flag from other builder" do
      b1 = builder
      b2 = builder.distinct
      b1.merge(b2)
      b1.distinct?.should be_true
    end

    it "does not set distinct when other is not distinct" do
      b1 = builder
      b2 = builder
      b1.merge(b2)
      b1.distinct?.should be_false
    end
  end
end
