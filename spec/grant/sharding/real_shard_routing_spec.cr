require "../../spec_helper"
require "../../support/real_sqlite_shards"
require "../../support/statement_recorder"

# Rows 1..10 live in two real SQLite files: odd ids (tenant 1) in :one, even
# ids (tenant 2) in :two. Every query below runs against those files, so the
# rows it returns prove the merge, not a recorded statement.
class S02RoutedThing < Grant::Base
  connection "s02_routing"
  table s02_routed_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String?
end

S02_ROUTING_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_routing", [:one, :two],
  ["CREATE TABLE s02_routed_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT)"]
)

describe "Sharded query routing over two real SQLite shard files" do
  before_all do
    S02_ROUTING_FIXTURE.set_up
    (1_i64..10_i64).each do |id|
      shard = id.odd? ? :one : :two
      S02_ROUTING_FIXTURE.exec(shard, "INSERT INTO s02_routed_things (id, tenant_id, label) VALUES (?, ?, ?)", id, id.odd? ? 1_i64 : 2_i64, "row #{id}")
    end
  end

  after_all do
    S02_ROUTING_FIXTURE.tear_down
  end

  it "keeps odd ids in shard one and even ids in shard two" do
    S02_ROUTING_FIXTURE.int_values(:one, "SELECT id FROM s02_routed_things ORDER BY id").should eq [1_i64, 3_i64, 5_i64, 7_i64, 9_i64]
    S02_ROUTING_FIXTURE.int_values(:two, "SELECT id FROM s02_routed_things ORDER BY id").should eq [2_i64, 4_i64, 6_i64, 8_i64, 10_i64]
  end

  it "merges the rows of every shard into one ordered result" do
    S02RoutedThing.order(id: :asc).select.map(&.id).should eq (1_i64..10_i64).to_a
    S02RoutedThing.order(id: :desc).select.map(&.id).should eq (1_i64..10_i64).to_a.reverse
  end

  it "applies OFFSET and LIMIT once, over the merged rows" do
    S02RoutedThing.order(id: :asc).limit(3).offset(2).select.map(&.id).should eq [3_i64, 4_i64, 5_i64]
    S02RoutedThing.order(id: :desc).limit(3).offset(2).select.map(&.id).should eq [8_i64, 7_i64, 6_i64]
  end

  it "applies an OFFSET with no LIMIT to the merged rows" do
    S02RoutedThing.order(id: :asc).offset(8).select.map(&.id).should eq [9_i64, 10_i64]
  end

  it "returns nothing when the offset is past the last row" do
    S02RoutedThing.order(id: :asc).limit(3).offset(10).select.should be_empty
  end

  it "returns a short page when fewer rows remain than the limit" do
    S02RoutedThing.order(id: :asc).limit(5).offset(8).select.map(&.id).should eq [9_i64, 10_i64]
  end

  it "sends limit plus offset and no OFFSET to each shard" do
    statements = StatementRecorder.statements do
      S02RoutedThing.order(id: :asc).limit(3).offset(2).select
    end
    selects = statements.select(&.includes?("s02_routed_things"))
    selects.size.should eq 2
    selects.each do |sql|
      sql.upcase.should contain "LIMIT 5"
      sql.upcase.should_not contain "OFFSET"
    end
  end

  it "orders by several columns across shards" do
    S02RoutedThing.order(tenant_id: :desc, id: :asc).limit(4).select.map(&.id).should eq [2_i64, 4_i64, 6_i64, 8_i64]
  end

  it "filters across shards and merges the matches" do
    S02RoutedThing.where("id > ?", 6_i64).order(id: :asc).select.map(&.id).should eq [7_i64, 8_i64, 9_i64, 10_i64]
  end

  it "routes a query that pins the shard key to one shard" do
    statements = StatementRecorder.statements do
      S02RoutedThing.where(tenant_id: 2_i64).order(id: :asc).select.map(&.id).should eq [2_i64, 4_i64, 6_i64, 8_i64, 10_i64]
    end
    statements.count(&.includes?("s02_routed_things")).should eq 1
  end

  it "counts and plucks across shards" do
    S02RoutedThing.count.should eq 10_i64
    S02RoutedThing.order(id: :asc).pluck(:id).map(&.as(Int64)).sort!.should eq (1_i64..10_i64).to_a
  end

  it "builds SQL for the adapter of the shard it runs on" do
    Grant::ShardManager.with_shard(:one) do
      S02RoutedThing.order(id: :asc).assembler.should be_a(Grant::Query::Assembler::Sqlite(S02RoutedThing))
    end
    Grant::Sharding::ShardedQueryBuilder(S02RoutedThing).db_type_for(Grant::Adapter::Pg.new(name: "s02_pg", url: "postgres://localhost/none")).should eq Grant::Query::Builder::DbType::Pg
    Grant::Sharding::ShardedQueryBuilder(S02RoutedThing).db_type_for(Grant::Adapter::Mysql.new(name: "s02_mysql", url: "mysql://localhost/none")).should eq Grant::Query::Builder::DbType::Mysql
  end
end
