require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class FindEachItem < Grant::Base
    connection {{ adapter_literal }}
    table find_each_items

    column id : Int64, primary: true
    column label : String
    column bucket : Int64
  end
{% end %}

private def seed_items(count : Int32 = 10) : Array(FindEachItem)
  FindEachItem.migrator.drop_and_create
  (1..count).map { |index| FindEachItem.create!(label: "item#{index}", bucket: (index % 3).to_i64) }
end

describe "find_each and find_in_batches" do
  it "yields every record once through the relation form" do
    items = seed_items
    seen = [] of Int64
    FindEachItem.where(:bucket, :gteq, 0_i64).find_each(batch_size: 3) { |item| seen << item.id! }
    seen.should eq(items.map(&.id!))
  end

  it "batches by a composite cursor that is not the primary key" do
    items = seed_items
    batches = [] of Array(Int64)
    FindEachItem.all.find_in_batches(batch_size: 4, cursor: [:bucket, :id]) do |batch|
      batches << batch.map(&.id!)
    end

    expected = items.sort_by { |item| {item.bucket, item.id!} }.map(&.id!)
    batches.flatten.should eq(expected)
    batches.map(&.size).should eq([4, 4, 2])
  end

  it "honors start, finish and descending order on the primary key" do
    items = seed_items
    ids = items.map(&.id!)

    seen = [] of Int64
    FindEachItem.all.find_each(batch_size: 2, start: ids[2], finish: ids[6]) { |item| seen << item.id! }
    seen.should eq(ids[2..6])

    descending = [] of Int64
    FindEachItem.all.find_each(batch_size: 3, order: :desc, start: ids[7], finish: ids[3]) { |item| descending << item.id! }
    descending.should eq(ids[3..7].reverse)
  end

  it "keeps the relation's order and limit, and applies its offset to the first batch only" do
    items = seed_items
    ids = items.map(&.id!)

    seen = [] of Int64
    FindEachItem.order(id: :desc).limit(5).find_each(batch_size: 2) { |item| seen << item.id! }
    seen.should eq(ids.reverse.first(5))

    skipped = [] of Int64
    FindEachItem.order(id: :asc).offset(3).find_each(batch_size: 2) { |item| skipped << item.id! }
    skipped.should eq(ids.skip(3))
  end

  it "ignores the relation order under an explicit cursor, or raises with error_on_ignore" do
    items = seed_items
    ids = items.map(&.id!)

    seen = [] of Int64
    FindEachItem.order(id: :desc).find_each(batch_size: 4, cursor: [:id]) { |item| seen << item.id! }
    seen.should eq(ids)

    expect_raises(Grant::BatchOptionIgnoredError, /cursor/) do
      FindEachItem.order(id: :desc).find_each(cursor: [:id], error_on_ignore: true) { |_item| }
    end

    FindEachItem.all.find_each(cursor: [:id], error_on_ignore: true) { |_item| }
  end

  it "rejects a batch size below one and an unknown order" do
    seed_items(1)
    expect_raises(ArgumentError) { FindEachItem.all.find_each(batch_size: 0) { |_item| } }
    expect_raises(ArgumentError) { FindEachItem.all.find_in_batches(order: :sideways) { |_batch| } }
  end

  it "returns lazy iterators that run one query per batch" do
    items = seed_items
    iterator = FindEachItem.all.find_in_batches(batch_size: 3)

    statements = capture_sql do
      first = iterator.next
      first.should be_a(Array(FindEachItem))
      first.as(Array(FindEachItem)).map(&.id!).should eq(items.first(3).map(&.id!))
    end
    statements.size.should eq(1)

    each_iterator = FindEachItem.all.find_each(batch_size: 4)
    each_iterator.first(5).map(&.id!).to_a.should eq(items.first(5).map(&.id!))
    FindEachItem.all.find_each(batch_size: 4).to_a.size.should eq(10)

    FindEachItem.all.find_in_batches(batch_size: 4).map(&.size).to_a.should eq([4, 4, 2])
  end

  it "pages with a keyset predicate and never OFFSET" do
    seed_items
    statements = capture_sql { FindEachItem.all.find_each(batch_size: 3) { |_item| } }

    statements.size.should eq(4)
    statements.each(&.should_not(contain("OFFSET")))
    statements[1..].each(&.should(contain(">")))
  end

  it "delegates Model.find_each and Model.find_in_batches to the keyset builder" do
    items = seed_items
    ids = items.map(&.id!)

    statements = capture_sql do
      seen = [] of Int64
      FindEachItem.find_each(batch_size: 4) { |item| seen << item.id! }
      seen.should eq(ids)
    end
    statements.each(&.should_not(contain("OFFSET")))

    batch_sizes = [] of Int32
    FindEachItem.find_in_batches(batch_size: 4, start: ids[1], cursor: [:id]) { |batch| batch_sizes << batch.size }
    batch_sizes.should eq([4, 4, 1])

    FindEachItem.find_each(batch_size: 4, finish: ids[4]).map(&.id!).to_a.should eq(ids.first(5))
    FindEachItem.find_each("WHERE bucket = ?", [1_i64] of Grant::Columns::Type, batch_size: 2).map(&.id!).to_a.should eq(items.select { |item| item.bucket == 1 }.map(&.id!))
    FindEachItem.find_each(batch_size: 3, offset: 4).map(&.id!).to_a.should eq(ids.skip(4))

    expect_raises(ArgumentError, /WHERE clause/) do
      FindEachItem.find_each("WHERE bucket = 1 ORDER BY id DESC") { |_item| }
    end
  end

  it "returns empty iterators for a none relation" do
    seed_items(3)
    statements = capture_sql do
      FindEachItem.none.find_each.to_a.should be_empty
      FindEachItem.none.find_in_batches.to_a.should be_empty
    end
    statements.should be_empty
  end

  it "does not mutate the source relation" do
    seed_items
    relation = FindEachItem.where(:bucket, :gteq, 0_i64)
    conditions = relation.where_fields.size
    relation.find_each(batch_size: 2) { |_item| }
    relation.where_fields.size.should eq(conditions)
    relation.order_fields.should be_empty
  end
end
