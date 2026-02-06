require "./spec_helper"

describe "Grant::Query::Builder - Joins" do
  describe "#joins" do
    it "adds an inner join clause" do
      query = builder.joins("posts", on: "posts.user_id = table.id")
      query.join_clauses.size.should eq 1
      query.join_clauses.first[:type].should eq :inner
      query.join_clauses.first[:table].should eq "posts"
      query.join_clauses.first[:on].should eq "posts.user_id = table.id"
    end

    it "chains joins with where conditions" do
      query = builder
        .joins("posts", on: "posts.user_id = table.id")
        .where(name: "bob")
      query.join_clauses.size.should eq 1
      query.where_fields.size.should eq 1
    end

    it "supports multiple joins" do
      query = builder
        .joins("posts", on: "posts.user_id = table.id")
        .joins("comments", on: "comments.post_id = posts.id")
      query.join_clauses.size.should eq 2
      query.join_clauses[0][:table].should eq "posts"
      query.join_clauses[1][:table].should eq "comments"
    end

    it "returns self for chaining" do
      query = builder.joins("posts", on: "posts.user_id = table.id")
      query.should be_a Grant::Query::Builder(Model)
    end
  end

  describe "#left_joins" do
    it "adds a left join clause" do
      query = builder.left_joins("posts", on: "posts.user_id = table.id")
      query.join_clauses.size.should eq 1
      query.join_clauses.first[:type].should eq :left
      query.join_clauses.first[:table].should eq "posts"
    end

    it "can be combined with inner joins" do
      query = builder
        .joins("posts", on: "posts.user_id = table.id")
        .left_joins("comments", on: "comments.post_id = posts.id")
      query.join_clauses.size.should eq 2
      query.join_clauses[0][:type].should eq :inner
      query.join_clauses[1][:type].should eq :left
    end
  end

  describe "dup preserves joins" do
    it "copies join clauses on dup" do
      original = builder.joins("posts", on: "posts.user_id = table.id")
      copy = original.dup
      copy.join_clauses.size.should eq 1
      copy.join_clauses.first[:table].should eq "posts"
    end

    it "dup creates independent copy" do
      original = builder.joins("posts", on: "posts.user_id = table.id")
      copy = original.dup
      copy.joins("comments", on: "comments.post_id = posts.id")
      original.join_clauses.size.should eq 1
      copy.join_clauses.size.should eq 2
    end
  end

  describe "merge preserves joins" do
    it "merges join clauses from another builder" do
      b1 = builder.joins("posts", on: "posts.user_id = table.id")
      b2 = builder.joins("comments", on: "comments.user_id = table.id")
      b1.merge(b2)
      b1.join_clauses.size.should eq 2
    end

    it "does not duplicate join clauses on merge" do
      b1 = builder.joins("posts", on: "posts.user_id = table.id")
      b2 = builder.joins("posts", on: "posts.user_id = table.id")
      b1.merge(b2)
      b1.join_clauses.size.should eq 1
    end
  end
end
