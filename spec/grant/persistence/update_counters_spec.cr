require "../../spec_helper"
require "../../support/write_sql_capture"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CounterTallyPost < Grant::Base
    connection {{ adapter_literal }}
    table counter_tally_posts

    column id : Int64, primary: true
    column title : String?
    column views_count : Int32?
    column likes_count : Int32?
    column big_count : Int64?
    column seen_at : Time?
    timestamps
  end
{% end %}

CounterTallyPost.migrator.drop_and_create

private def updates_in(statements : Array(String)) : Array(String)
  statements.select(&.match(/\A\[[^\]]*\]\s+UPDATE\b/i))
end

STAMP = Time.utc(2020, 1, 2, 3, 4, 5)

describe ".update_counters" do
  before_each { CounterTallyPost.clear }

  it "adjusts two counter columns in one statement" do
    post = CounterTallyPost.create!(title: "p", views_count: 10, likes_count: 4)
    statements = WriteSqlCapture.statements do
      CounterTallyPost.update_counters(post.id!, {:views_count => 5, :likes_count => -1}).should eq(1)
    end
    updates_in(statements).size.should eq(1)

    reloaded = CounterTallyPost.find!(post.id)
    reloaded.views_count.should eq(15)
    reloaded.likes_count.should eq(3)
  end

  it "updates every id in an array with one statement" do
    posts = Array.new(3) { |i| CounterTallyPost.create!(title: "p#{i}", views_count: i) }
    untouched = CounterTallyPost.create!(title: "other", views_count: 100)

    statements = WriteSqlCapture.statements do
      CounterTallyPost.update_counters(posts.map(&.id!), {:views_count => 10}).should eq(3)
    end
    updates = updates_in(statements)
    updates.size.should eq(1)
    updates.first.should match(/ IN /i)

    posts.each_with_index do |post, i|
      CounterTallyPost.find!(post.id).views_count.should eq(i + 10)
    end
    CounterTallyPost.find!(untouched.id).views_count.should eq(100)
  end

  it "counts a NULL column as zero" do
    post = CounterTallyPost.create!(title: "p")
    CounterTallyPost.update_counters(post.id!, {:views_count => 2})
    CounterTallyPost.find!(post.id).views_count.should eq(2)
  end

  it "accepts Int64 deltas" do
    post = CounterTallyPost.create!(title: "p", big_count: 5_i64)
    CounterTallyPost.update_counters(post.id!, {:big_count => 4_000_000_000_i64})
    CounterTallyPost.find!(post.id).big_count.should eq(4_000_000_005_i64)
  end

  it "does not touch updated_at unless asked" do
    post = CounterTallyPost.create!(title: "p", views_count: 0)
    post.touch(time: STAMP)
    CounterTallyPost.update_counters(post.id!, {:views_count => 1})
    CounterTallyPost.find!(post.id).updated_at.not_nil!.to_utc.should eq(STAMP)
  end

  it "touches updated_at in the same statement with touch: true" do
    post = CounterTallyPost.create!(title: "p", views_count: 0)
    post.touch(time: STAMP)
    statements = WriteSqlCapture.statements do
      CounterTallyPost.update_counters(post.id!, {:views_count => 1}, touch: true)
    end
    updates_in(statements).size.should eq(1)
    CounterTallyPost.find!(post.id).updated_at.not_nil!.to_utc.should be > STAMP
  end

  it "touches named columns as well" do
    post = CounterTallyPost.create!(title: "p", views_count: 0)
    post.touch(time: STAMP)
    CounterTallyPost.update_counters([post.id!], {:views_count => 1}, touch: [:seen_at])
    reloaded = CounterTallyPost.find!(post.id)
    reloaded.seen_at.should_not be_nil
    reloaded.updated_at.not_nil!.to_utc.should be > STAMP
  end

  it "rejects an unknown touch column" do
    post = CounterTallyPost.create!(title: "p", views_count: 0)
    expect_raises(ArgumentError, /nope/) { CounterTallyPost.update_counters(post.id!, {:views_count => 1}, touch: :nope) }
  end

  it "returns 0 for an empty list, a missing id and no counters" do
    CounterTallyPost.update_counters([] of Int64, {:views_count => 1}).should eq(0)
    CounterTallyPost.update_counters(999_999, {:views_count => 1}).should eq(0)
    post = CounterTallyPost.create!(title: "p", views_count: 1)
    CounterTallyPost.update_counters(post.id!, {} of Symbol => Int32).should eq(0)
  end
end
