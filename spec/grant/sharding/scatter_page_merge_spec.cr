require "../../spec_helper"
require "../../support/real_sqlite_shards"

# Rows 1..10 live in two real SQLite files: odd ids (tenant 1) in :one, even
# ids (tenant 2) in :two. The examples prove that count, pluck and exists?
# apply ORDER BY, LIMIT and OFFSET once over the merged shards, the way a
# single database would, rather than once per shard.
class S02PageMergeThing < Grant::Base
  connection "s02_page_merge"
  table s02_page_merge_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
end

S02_PAGE_MERGE_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_page_merge", [:one, :two],
  ["CREATE TABLE s02_page_merge_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT)"]
)

describe "Scatter-gather pages for count, pluck and exists?" do
  before_all do
    S02_PAGE_MERGE_FIXTURE.set_up
    (1_i64..10_i64).each do |id|
      shard = id.odd? ? :one : :two
      label = id == 4_i64 ? nil : "row #{id}"
      S02_PAGE_MERGE_FIXTURE.exec(shard, "INSERT INTO s02_page_merge_things (id, tenant_id, label) VALUES (?, ?, ?)", id, id.odd? ? 1_i64 : 2_i64, label)
    end
  end

  after_all do
    S02_PAGE_MERGE_FIXTURE.tear_down
  end

  describe "#count" do
    it "counts a limited relation once, not once per shard" do
      S02PageMergeThing.order(id: :asc).limit(3).count.should eq 3_i64
    end

    it "counts what is left after a global offset" do
      S02PageMergeThing.order(id: :asc).offset(8).count.should eq 2_i64
      S02PageMergeThing.order(id: :asc).limit(5).offset(8).count.should eq 2_i64
      S02PageMergeThing.order(id: :asc).limit(5).offset(20).count.should eq 0_i64
    end

    it "refuses a grouped count with LIMIT that spans shards" do
      expect_raises(Grant::Sharding::ScatterAggregateError) do
        S02PageMergeThing.group(:tenant_id).limit(1).count
      end
    end
  end

  describe "#pluck" do
    it "returns plucked values in the merged ORDER BY" do
      S02PageMergeThing.order(id: :desc).pluck(:id).should eq (1_i64..10_i64).to_a.reverse.map(&.as(Grant::Columns::Type))
    end

    it "applies LIMIT and OFFSET once over the merged rows" do
      S02PageMergeThing.order(id: :asc).limit(3).offset(2).pluck(:id).should eq [3_i64, 4_i64, 5_i64].map(&.as(Grant::Columns::Type))
    end

    it "orders by a column it does not pluck" do
      S02PageMergeThing.order(id: :asc).limit(3).offset(4).pluck(:label).should eq ["row 5", "row 6", "row 7"].map(&.as(Grant::Columns::Type))
    end

    it "skips NULL values after the page is cut, as a single database does" do
      S02PageMergeThing.order(id: :asc).limit(3).offset(2).pluck(:label).should eq ["row 3", "row 5"].map(&.as(Grant::Columns::Type))
    end
  end

  describe "#exists?" do
    it "honors a global offset" do
      S02PageMergeThing.order(id: :asc).offset(9).exists?.should be_true
      S02PageMergeThing.order(id: :asc).offset(10).exists?.should be_false
    end
  end
end
