require "../../spec_helper"

class W6moItem < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6mo_items

  column id : Int64, primary: true
  column name : String?
  column rank : Int32 = 0
  column kind : String?
  column seq : Int32 = 0
end

# The rows' creation order, so the spec does not depend on generated ids.
private def seqs(relation : Grant::Query::Builder(W6moItem)) : Array(Int32)
  relation.select.map(&.seq)
end

describe "merge ORDER BY" do
  before_all { W6moItem.migrator.drop_and_create }
  before_each do
    W6moItem.clear
    W6moItem.create!(name: "b", rank: 1, kind: "x", seq: 1)
    W6moItem.create!(name: "a", rank: 2, kind: "x", seq: 2)
    W6moItem.create!(name: "a", rank: 1, kind: "y", seq: 3)
    W6moItem.create!(name: "b", rank: 2, kind: "y", seq: 4)
  end

  it "appends the other relation's order after the receiver's" do
    merged = W6moItem.order(:name).merge(W6moItem.order(rank: :desc))
    merged.to_sql.should contain("ORDER BY")
    merged.order_fields.map { |term| term[:field] }.should eq(["name", "rank"])
    seqs(merged).should eq([2, 3, 4, 1])
  end

  it "orders by the receiver first, then breaks ties with the merged relation" do
    # name ASC puts the two "a" rows first; rank DESC then sorts inside each name.
    seqs(W6moItem.order(:name).merge(W6moItem.order(rank: :desc))).first(2).should eq([2, 3])
    seqs(W6moItem.order(:name).merge(W6moItem.order(rank: :asc))).first(2).should eq([3, 2])
  end

  it "does not repeat a term the receiver already orders by" do
    merged = W6moItem.order(:name).merge(W6moItem.order(:name).order(:rank))
    merged.order_fields.map { |term| term[:field] }.should eq(["name", "rank"])
  end

  it "keeps the receiver's order when the other relation has none" do
    seqs(W6moItem.order(rank: :desc, seq: :asc).merge(W6moItem.where(kind: "x"))).should eq([2, 1])
  end

  it "takes the other relation's order when the receiver has none" do
    seqs(W6moItem.where(kind: "x").merge(W6moItem.order(seq: :desc))).should eq([2, 1])
  end

  it "lets a reordered relation replace the receiver's order" do
    merged = W6moItem.order(:name).merge(W6moItem.reorder(rank: :desc, seq: :asc))
    merged.order_fields.map { |term| term[:field] }.should eq(["rank", "seq"])
    seqs(merged).should eq([2, 4, 1, 3])
  end

  it "lets reorder(nil) on the merged relation drop the receiver's order" do
    W6moItem.order(:name).merge(W6moItem.reorder(nil)).order_fields.should be_empty
  end

  it "appends through the block and keyword forms" do
    merged = W6moItem.order(:name).merge { |scope| scope.order(rank: :desc) }
    merged.order_fields.map { |term| term[:field] }.should eq(["name", "rank"])
    W6moItem.order(:name).merge(kind: "x").order_fields.map { |term| term[:field] }.should eq(["name"])
  end

  it "appends when a named-scope style relation is merged with merge_builder" do
    base = W6moItem.order(:name).where(kind: "x")
    merged = base.merge(W6moItem.order(:rank))
    merged.order_fields.map { |term| term[:field] }.should eq(["name", "rank"])
    merged.to_sql.scan("ORDER BY").size.should eq(1)
  end

  it "keeps raw order terms when merging" do
    merged = W6moItem.order("lower(name) DESC").merge(W6moItem.order(:seq))
    merged.to_sql.should contain("lower(name) DESC")
    merged.to_sql.should contain("ORDER BY")
    seqs(merged).first.should eq(1)
  end

  it "leaves both relations unchanged" do
    left = W6moItem.order(:name)
    right = W6moItem.order(:rank)
    left.merge(right)
    left.order_fields.map { |term| term[:field] }.should eq(["name"])
    right.order_fields.map { |term| term[:field] }.should eq(["rank"])
  end

  it "takes the other relation's from source and common table expressions" do
    merged = W6moItem.where(kind: "x").merge(W6moItem.from(W6moItem.where(rank: 2), as: "sub"))
    merged.to_sql.should contain("sub")
    seqs(merged).should eq([2])
    with_cte = W6moItem.where(kind: "x").merge(W6moItem.with(:picked, W6moItem.where(kind: "y")))
    with_cte.to_sql.should contain("WITH")
    seqs(with_cte).should eq([1, 2])
  end

  it "applies the unscoping of the merged relation" do
    merged = W6moItem.where(kind: "x").order(:name).merge(W6moItem.unscope(:where))
    seqs(merged).size.should eq(4)
    merged = W6moItem.where(kind: "x").where(rank: 1).merge(W6moItem.unscope(where: :kind))
    seqs(merged).should eq([1, 3])
    merged = W6moItem.where(kind: "x").order(:name).merge(W6moItem.unscope(:order))
    merged.order_fields.should be_empty
  end
end

class W6moPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6mo_posts

  column id : Int64, primary: true
  column status : String?
  column rank : Int32 = 0

  scope :drafts, -> { W6moPost.where(status: "draft") }
  scope :by_rank, -> { W6moPost.order(rank: :desc) }
  scope :by_id, ->(q : Grant::Query::Builder(W6moPost)) { q.order(:id) }
end

describe "named scopes merge like relations" do
  before_all { W6moPost.migrator.drop_and_create }
  before_each do
    W6moPost.clear
    W6moPost.create!(status: "draft", rank: 1)
    W6moPost.create!(status: "live", rank: 2)
    W6moPost.create!(status: "draft", rank: 3)
  end

  it "replaces a same-column equality from an earlier where" do
    relation = W6moPost.by_id.where(status: "live").drafts
    relation.to_sql.split("WHERE").last.scan("status").size.should eq(1)
    relation.select.map(&.rank).should eq([1, 3])
  end

  it "keeps conditions on other columns" do
    W6moPost.by_id.where(rank: 3).drafts.select.map(&.rank).should eq([3])
  end

  it "appends the scope's order to the existing order" do
    relation = W6moPost.by_id.order(:status).by_rank
    relation.order_fields.map { |term| term[:field] }.should eq(["id", "status", "rank"])
    relation.drafts.order_fields.map { |term| term[:field] }.should eq(["id", "status", "rank"])
  end

  it "appends the order of a scope that takes the relation" do
    relation = W6moPost.by_rank.by_id
    relation.order_fields.map { |term| term[:field] }.should eq(["rank", "id"])
  end
end
