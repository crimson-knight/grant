require "../../spec_helper"
require "../../support/relation_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class InBatchesItem < Grant::Base
    connection {{ adapter_literal }}
    table in_batches_items

    column id : Int64, primary: true
    column label : String
    column archived : Bool = false
  end
{% end %}

private def seed_batch_items(count : Int32 = 7) : Array(InBatchesItem)
  InBatchesItem.migrator.drop_and_create
  (1..count).map { |index| InBatchesItem.create!(label: "item#{index}") }
end

describe "in_batches yielding relations" do
  it "yields a relation whose update_all and delete_all run in SQL" do
    items = seed_batch_items
    ids = items.map(&.id!)
    yielded = [] of InBatchesItem.class | Grant::Query::Builder(InBatchesItem).class

    statements = capture_sql do
      InBatchesItem.all.in_batches(of: 3) do |batch|
        yielded << batch.class
        batch.update_all(archived: true).should be > 0
      end
    end

    yielded.size.should eq(3)
    InBatchesItem.where(archived: true).count.should eq(7)
    statements.count(&.starts_with?("SELECT")).should eq(3)
    statements.select(&.starts_with?("SELECT")).each { |sql| sql.should_not contain("label") }

    removed = 0_i64
    InBatchesItem.where(:id, :lteq, ids[4]).in_batches(of: 2) { |batch| removed += batch.delete_all }
    removed.should eq(5)
    InBatchesItem.pluck(:id).flatten.should eq(ids.skip(5))
  end

  it "plucks only the keys per batch and does not load records" do
    seed_batch_items
    statements = capture_sql do
      InBatchesItem.all.in_batches(of: 4) { |_batch| }
    end

    statements.size.should eq(2)
    statements.each { |sql| sql.should_not contain("OFFSET") }
    statements.each { |sql| sql.should_not contain("label") }
  end

  it "supports pluck, count and enumeration on the batch relation" do
    items = seed_batch_items
    ids = items.map(&.id!)

    plucked = [] of Array(Int64)
    InBatchesItem.all.in_batches(of: 3) do |batch|
      batch.to_a.size.should be <= 3
      plucked << batch.pluck(:id).map { |row| row.first.as(Int64) }
    end
    plucked.flatten.should eq(ids)

    firsts = [] of String
    InBatchesItem.all.in_batches(of: 3, order: :desc) { |batch| firsts << batch.first!.label }
    firsts.first.should eq("item7")
  end

  it "memoizes the records with load: true" do
    seed_batch_items
    labels = [] of String

    statements = capture_sql do
      InBatchesItem.all.in_batches(of: 4, load: true) do |batch|
        batch.loaded?.should be_true
        batch.each { |item| labels << item.label }
        batch.to_a.size.should be <= 4
      end
    end

    labels.size.should eq(7)
    statements.size.should eq(2)
    statements.each(&.should(start_with("SELECT")))
  end

  it "returns a lazy iterator of batch relations" do
    seed_batch_items
    iterator = InBatchesItem.all.in_batches(of: 3)

    statements = capture_sql do
      first = iterator.next.as(Grant::Query::Builder(InBatchesItem))
      first.to_a.size.should eq(3)
    end
    statements.size.should eq(2)

    InBatchesItem.all.in_batches(of: 3).map { |batch| batch.to_a.size }.to_a.should eq([3, 3, 1])
  end

  it "applies start, finish, cursor and error_on_ignore like find_each" do
    items = seed_batch_items
    ids = items.map(&.id!)

    seen = [] of Int64
    InBatchesItem.all.in_batches(of: 2, start: ids[1], finish: ids[5]) do |batch|
      batch.pluck(:id).each { |row| seen << row.first.as(Int64) }
    end
    seen.should eq(ids[1..5])

    expect_raises(Grant::BatchOptionIgnoredError) do
      InBatchesItem.order(:label).in_batches(cursor: [:id], error_on_ignore: true) { |_batch| }
    end
  end

  it "keeps the source relation untouched and yields nothing for an empty or none relation" do
    seed_batch_items
    relation = InBatchesItem.where(archived: false)
    before = relation.where_fields.size
    relation.in_batches(of: 2) { |_batch| }
    relation.where_fields.size.should eq(before)

    called = false
    InBatchesItem.where(label: "missing").in_batches { |_batch| called = true }
    InBatchesItem.none.in_batches { |_batch| called = true }
    called.should be_false
  end

  it "delegates Model.in_batches" do
    seed_batch_items
    counts = [] of Int64
    InBatchesItem.in_batches(of: 3) { |batch| counts << batch.to_a.size }
    counts.should eq([3, 3, 1])
  end
end
