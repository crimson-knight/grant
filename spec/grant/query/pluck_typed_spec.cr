require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PtAuthor < Grant::Base
    connection {{ adapter_literal }}
    table pt_authors
    column id : Int64, primary: true
    column name : String
    has_many :items, class_name: PtItem, foreign_key: :pt_author_id
  end

  class PtItem < Grant::Base
    connection {{ adapter_literal }}
    table pt_items
    column id : Int64, primary: true
    column title : String
    column qty : Int64
    column price : Float64
    column tag : String?
    column pt_author_id : Int64?
    belongs_to :pt_author, class_name: PtAuthor, foreign_key: :pt_author_id, optional: true
  end
{% end %}

describe "typed pluck and pick" do
  before_all do
    PtAuthor.migrator.drop_and_create
    PtItem.migrator.drop_and_create
  end

  before_each do
    PtItem.clear
    PtAuthor.clear
    ada = PtAuthor.create!(name: "Ada")
    PtItem.create!(title: "pen", qty: 3_i64, price: 1.5, tag: "office", pt_author_id: ada.id)
    PtItem.create!(title: "ink", qty: 5_i64, price: 4.25, tag: nil, pt_author_id: ada.id)
    PtItem.create!(title: "pad", qty: 1_i64, price: 2.0, tag: "office")
  end

  it "returns tuples of the requested types" do
    rows = PtItem.order(:id).pluck_as(id: Int64, title: String, price: Float64)
    rows.size.should eq(3)
    rows.first.should be_a(Tuple(Int64, String, Float64))
    rows.map(&.[1]).should eq(["pen", "ink", "pad"])
    rows.map(&.[2]).should eq([1.5, 4.25, 2.0])
  end

  it "reads a single column" do
    PtItem.order(:id).pluck_as(qty: Int64).should eq([{3_i64}, {5_i64}, {1_i64}])
  end

  it "reads nullable columns as nilable types" do
    PtItem.order(:id).pluck_as(tag: String?).should eq([{"office"}, {nil}, {"office"}])
  end

  it "raises when the value does not fit the requested type" do
    expect_raises(Exception) { PtItem.order(:id).pluck_as(tag: String) }
  end

  it "respects where, order, limit and offset" do
    PtItem.where(tag: "office").order(title: :desc).pluck_as(title: String).should eq([{"pen"}, {"pad"}])
    PtItem.order(:id).limit(1).offset(1).pluck_as(title: String).should eq([{"ink"}])
  end

  it "plucks SQL expressions named by a quoted key" do
    PtItem.pluck_as("COUNT(*)": Int64).should eq([{3_i64}])
    PtItem.order(:id).pluck_as("upper(title)": String).should eq([{"PEN"}, {"INK"}, {"PAD"}])
    PtItem.group(:tag).order(:tag, nulls: :first).pluck_as(tag: String?, "COUNT(*)": Int64).should eq([{nil, 1_i64}, {"office", 2_i64}])
  end

  it "plucks joined-table columns by qualified name" do
    rows = PtItem.joins(:pt_author).order("pt_items.id").pluck_as("pt_items.title": String, "pt_authors.name": String)
    rows.should eq([{"pen", "Ada"}, {"ink", "Ada"}])
    PtItem.joins(:pt_author).order("pt_items.id").pluck("pt_authors.name", :title).should eq([["Ada", "pen"], ["Ada", "ink"]])
  end

  it "picks the first row as a tuple, or nil" do
    PtItem.order(:id).pick_as(id: Int64, title: String).try(&.[1]).should eq("pen")
    PtItem.where(title: "nothing").pick_as(id: Int64).should be_nil
    PtItem.order(qty: :desc).pick_as(title: String).should eq({"ink"})
  end

  it "returns an empty array for a none relation" do
    PtItem.none.pluck_as(id: Int64).should eq([] of Tuple(Int64))
  end

  it "reads across a chunked IN list" do
    ids = PtItem.order(:id).ids.map(&.as(Int64))
    PtItem.where(id: ids).in_chunks(of: 2).pluck_as(title: String).map(&.first).sort!.should eq(["ink", "pad", "pen"])
  end

  it "is available on the model class" do
    PtItem.pluck_as(title: String).size.should eq(3)
    PtItem.pick_as(id: Int64).should_not be_nil
  end

  it "reads values directly, without boxing into Grant::Columns::Type" do
    # The tuple element types are the requested ones, not the Columns::Type union.
    typeof(PtItem.pluck_as(id: Int64, title: String)).should eq(Array(Tuple(Int64, String)))
  end

  it "plucks untyped SQL expressions through pluck(String)" do
    PtItem.all.pluck("COUNT(*)").should eq([[3_i64]])
    PtItem.order(:id).pluck("qty * 2").map(&.first).should eq([6_i64, 10_i64, 2_i64])
  end

  it "refuses an expression that is not a single clause" do
    expect_raises(ArgumentError, /statement separator/) { PtItem.all.pluck("id; DROP TABLE pt_items") }
    expect_raises(ArgumentError, /comment marker/) { PtItem.pluck_as("id -- x": Int64) }
  end
end
