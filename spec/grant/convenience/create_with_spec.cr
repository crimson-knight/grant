require "../../spec_helper"
require "../../support/convenience_models"

describe "create_with" do
  before_all { ConvenienceSpecSupport.reset_items }
  before_each { ConvItem.clear }

  it "supplies defaults for create and build" do
    relation = ConvItem.create_with(status: "draft", qty: 5)
    item = relation.create(name: "a")
    item.status.should eq("draft")
    item.qty.should eq(5)
    relation.build(name: "b").status.should eq("draft")
  end

  it "lets explicit attributes win over the defaults" do
    ConvItem.create_with(status: "draft").create(name: "a", status: "live").status.should eq("live")
  end

  it "overrides scope attributes from the where clause" do
    item = ConvItem.where(status: "live").create_with(status: "draft").create(name: "a")
    item.status.should eq("draft")
  end

  it "merges successive calls" do
    relation = ConvItem.create_with(status: "draft").create_with(kind: "k")
    relation.create_with_attributes.should eq({"status" => "draft", "kind" => "k"})
  end

  it "clears the defaults when given an empty hash" do
    relation = ConvItem.create_with(status: "draft").create_with(Grant::ModelArgs.new)
    relation.create_with_attributes.empty?.should be_true
  end

  it "copies the defaults when the relation is duplicated" do
    parent = ConvItem.create_with(status: "draft")
    child = parent.create_with(kind: "child")
    parent.create_with_attributes.should eq({"status" => "draft"})
    child.create_with_attributes.should eq({"status" => "draft", "kind" => "child"})

    copy = parent.dup
    copy.create_with!({"status" => "live"} of Symbol | String => Grant::Columns::Type)
    parent.build(name: "p").status.should eq("draft")
    copy.build(name: "c").status.should eq("live")
  end

  it "returns a copy of the defaults so callers cannot alter the relation" do
    relation = ConvItem.create_with(status: "draft")
    relation.create_with_attributes["status"] = "tampered"
    relation.build(name: "x").status.should eq("draft")
  end

  it "survives further chaining" do
    relation = ConvItem.create_with(status: "draft").where(kind: "k").order(id: :desc)
    item = relation.create(name: "chain")
    item.status.should eq("draft")
    item.kind.should eq("k")
  end

  it "applies to find_or_create_by and create_or_find_by" do
    relation = ConvItem.create_with(status: "draft")
    relation.find_or_create_by(name: "a").status.should eq("draft")
    relation.create_or_find_by(name: "b").status.should eq("draft")
  end

  it "reports scope attributes from equality predicates only" do
    ConvItem.where(status: "x", kind: "y").where(:qty, :gt, 3).scope_attributes.should eq({"status" => "x", "kind" => "y"})
    ConvItem.scope_attributes.empty?.should be_true
  end

  it "is available on the class" do
    ConvItem.create_with(kind: "k").create(name: "a").kind.should eq("k")
  end

  it "ignores equality predicates on other tables and unknown columns" do
    qualified = {"conv_items.status" => "own", "authors.id" => 5_i64, "other.kind" => "k", "not_a_column" => "x"} of Symbol | String => Grant::Columns::Type
    ConvItem.where(qualified).scope_attributes.should eq({"status" => "own"})
  end

  it "keeps create_with defaults set inside a named scope body" do
    item = ConvItem.drafts.kinded.create(name: "r")
    item.kind.should eq("k")
    item.qty.should eq(1)
    item.status.should eq("draft")
    ConvItem.kinded.build(name: "s").kind.should eq("k")
  end
end
