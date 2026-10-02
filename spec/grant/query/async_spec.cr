require "../../spec_helper"

class AsyncQ05Item < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table async_q05_items

  column id : Int64, primary: true
  column name : String?
  column score : Int32?
end

private def with_async_pool_size(size : Int32, &)
  previous = Grant.settings.async_pool_size
  Grant.settings.async_pool_size = size
  begin
    yield
  ensure
    Grant.settings.async_pool_size = previous
  end
end

describe "async queries" do
  before_each do
    AsyncQ05Item.migrator.drop_and_create
    AsyncQ05Item.create(name: "a", score: 10)
    AsyncQ05Item.create(name: "b", score: 20)
    AsyncQ05Item.create(name: "c", score: 30)
  end

  describe "async_ids" do
    it "loads the primary keys of a relation on a fiber" do
      expected = AsyncQ05Item.where("score >= ?", 20).ids
      AsyncQ05Item.where("score >= ?", 20).async_ids.wait.should eq expected
      expected.size.should eq 2
    end

    it "loads the keys of the model's current scope" do
      AsyncQ05Item.async_ids.wait.should eq AsyncQ05Item.ids
    end
  end

  describe "async_pick" do
    it "picks the first value of a column, ordered by key" do
      AsyncQ05Item.async_pick(:name).wait.should eq "a"
      AsyncQ05Item.where("score > ?", 15).order(:score).async_pick(:name).wait.should eq "b"
      AsyncQ05Item.where(name: "zzz").async_pick(:name).wait.should be_nil
    end
  end

  describe "async_exists?" do
    it "answers on a fiber for the model and for a relation" do
      AsyncQ05Item.async_exists?.wait.should be_true
      AsyncQ05Item.where(name: "a").async_exists?.wait.should be_true
      AsyncQ05Item.where(name: "zzz").async_exists?.wait.should be_false
    end
  end

  describe "async_average and async_find_by_sql" do
    it "averages a column" do
      AsyncQ05Item.async_average(:score).wait.should eq 20.0
      AsyncQ05Item.where("score > ?", 10).async_average(:score).wait.should eq 25.0
    end

    it "hydrates raw SQL on a fiber" do
      table = AsyncQ05Item.table_name
      rows = AsyncQ05Item.async_find_by_sql("SELECT * FROM #{table} WHERE score > ?", [10] of Grant::Columns::Type).wait
      rows.map(&.name).compact.sort.should eq ["b", "c"]
    end
  end

  describe "Grant.settings.async_pool_size" do
    it "defaults to four and rejects values below one" do
      Grant.settings.async_pool_size.should eq 4
      expect_raises(ArgumentError) { Grant.settings.async_pool_size = 0 }
    end

    it "caps how many async blocks run at once" do
      with_async_pool_size(2) do
        running = Atomic(Int32).new(0)
        peak = Atomic(Int32).new(0)
        results = Array(Grant::Async::Result(Int32)).new
        8.times do |index|
          results << Grant::Async::Result(Int32).new do
            now = running.add(1) + 1
            loop do
              seen = peak.get
              break if now <= seen || peak.compare_and_set(seen, now)[1]
            end
            sleep 20.milliseconds
            running.sub(1)
            index
          end
        end
        results.map(&.wait).should eq (0...8).to_a
        peak.get.should be <= 2
        peak.get.should be >= 1
      end
    end

    it "bounds concurrent async queries the same way" do
      with_async_pool_size(1) do
        results = Array(Grant::Async::Result(Int64)).new
        6.times { results << AsyncQ05Item.async_count }
        results.map(&.wait).should eq [3_i64] * 6
      end
    end

    it "does not deadlock chained results when the cap is one" do
      with_async_pool_size(1) do
        chained = AsyncQ05Item.async_count.then { |count| count * 2 }.map { |count| count + 1 }
        chained.wait.should eq 7
      end
    end

    it "does not deadlock a result started from inside an async fiber" do
      with_async_pool_size(1) do
        outer = Grant::Async::Result(Int64).new { AsyncQ05Item.async_count.wait }
        outer.wait.should eq 3
      end
    end

    it "frees the slot when a block raises" do
      with_async_pool_size(1) do
        failing = Grant::Async::Result(Int32).new { raise "nope" }
        expect_raises(Exception, "nope") { failing.wait }
        Grant::Async::Result(Int32).new { 5 }.wait.should eq 5
      end
    end
  end
end
