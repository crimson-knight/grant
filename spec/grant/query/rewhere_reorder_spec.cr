require "../../spec_helper"
require "../../support/where_family_models"

private def titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.select.map { |post| post.title.to_s }
end

describe "rewhere, reorder and reverse_order" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    WfPost.create!(title: "a", published: true, score: 1)
    WfPost.create!(title: "b", published: false, score: 2)
    WfPost.create!(title: "c", published: true, score: 3)
  end

  describe "rewhere" do
    it "replaces the conditions on its own columns and keeps the others" do
      relation = WfPost.where(published: true, score: 3).rewhere(published: false)
      relation.to_sql.split("WHERE").last.should contain("score")
      titles(relation).should eq([] of String)
      titles(WfPost.where(published: true, score: 2).rewhere(published: false)).should eq(["b"])
    end

    it "replaces every kind of condition on the column" do
      titles(WfPost.where(score: 1..2).where(published: true).rewhere(score: 3)).should eq(["c"])
      titles(WfPost.where(score: [1, 2]).rewhere(score: 3)).should eq(["c"])
    end

    it "replaces nil-aware lists, arrays holding ranges and record lists" do
      titles(WfPost.where(score: [1, nil]).rewhere(score: 3)).should eq(["c"])
      titles(WfPost.where(score: [1, 3..4]).rewhere(score: 2)).should eq(["b"])

      ann = WfAuthor.create!(name: "ann")
      bob = WfAuthor.create!(name: "bob")
      cy = WfAuthor.create!(name: "cy")
      WfPost.create!(title: "by cy", author_id: cy.id)
      titles(WfPost.where(author: [ann, bob]).rewhere(author: cy)).should eq(["by cy"])
      titles(WfPost.where(author: [ann, nil]).rewhere(author: cy)).should eq(["by cy"])
    end

    it "keeps a copied relation's list conditions apart from the receiver's" do
      base = WfPost.where(published: true)
      with_list = base.where(score: [3, nil])
      base.where(score: [1, nil]).rewhere(score: 2)
      titles(with_list.rewhere(score: 1)).should eq(["a"])
      titles(base).sort.should eq(["a", "c"])
    end

    it "behaves like where for a column with no condition yet" do
      titles(WfPost.where(published: true).rewhere(score: 3)).should eq(["c"])
    end

    it "takes a hash" do
      titles(WfPost.where(published: true, score: 2).rewhere({published: false})).should eq(["b"])
    end

    it "leaves the receiver untouched" do
      base = WfPost.where(published: true)
      base.rewhere(published: false)
      titles(base).should eq(["a", "c"])
    end
  end

  describe "reorder" do
    it "replaces the order" do
      titles(WfPost.order(score: :asc).reorder(score: :desc)).should eq(["c", "b", "a"])
      titles(WfPost.order(score: :desc).reorder(:score)).should eq(["a", "b", "c"])
    end

    it "takes several symbols" do
      relation = WfPost.order(score: :desc).reorder(:published, :score)
      relation.to_sql.should contain("ORDER BY published ASC, score ASC")
      titles(relation).should eq(["b", "a", "c"])
    end

    it "takes an array" do
      titles(WfPost.order(score: :desc).reorder([:published, :score])).should eq(["b", "a", "c"])
    end

    it "clears the order with nil" do
      relation = WfPost.order(score: :desc).reorder(nil)
      relation.to_sql.should_not contain("score DESC")
      relation.order_fields.should be_empty
    end

    it "does not touch the receiver" do
      base = WfPost.order(score: :desc)
      base.reorder(nil)
      titles(base).should eq(["c", "b", "a"])
    end
  end

  describe "reverse_order" do
    it "flips an explicit order" do
      titles(WfPost.order(score: :asc).reverse_order).should eq(["c", "b", "a"])
    end

    it "reverses the primary key order of an unordered relation" do
      relation = WfPost.all.reverse_order
      relation.to_sql.should contain("ORDER BY id DESC")
      titles(relation).should eq(["c", "b", "a"])
      titles(WfPost.where(published: true).reverse_order).should eq(["c", "a"])
    end

    it "is its own inverse" do
      titles(WfPost.all.reverse_order.reverse_order).should eq(["a", "b", "c"])
    end

    it "still lets first and last work" do
      WfPost.all.reverse_order.first!.title.should eq("c")
      WfPost.order(:score).last!.title.should eq("c")
    end
  end

  describe "reselect and regroup" do
    it "reselect replaces the projection" do
      WfPost.select(:id, :title).reselect(:id, :score).to_sql.should contain("SELECT id, score FROM")
    end

    it "regroup replaces the grouping" do
      WfPost.group_by(:published).regroup(:score).to_sql.should contain("GROUP BY score")
    end
  end
end
