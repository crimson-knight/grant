require "../../spec_helper"
require "../../support/real_sqlite_shards"
require "../../support/statement_recorder"

# Shard one holds ids 1..7 and shard two holds ids 101..105, in two real files.
class S02BatchThing < Grant::Base
  connection "s02_batches"
  table s02_batch_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
end

S02_BATCH_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_batches", [:one, :two],
  ["CREATE TABLE s02_batch_things (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL)"]
)

describe "find_each across shards" do
  before_all do
    S02_BATCH_FIXTURE.set_up
    (1_i64..7_i64).each { |id| S02_BATCH_FIXTURE.exec(:one, "INSERT INTO s02_batch_things (id, tenant_id) VALUES (?, 1)", id) }
    (101_i64..105_i64).each { |id| S02_BATCH_FIXTURE.exec(:two, "INSERT INTO s02_batch_things (id, tenant_id) VALUES (?, 2)", id) }
  end

  after_all do
    S02_BATCH_FIXTURE.tear_down
  end

  it "yields every record exactly once" do
    ids = [] of Int64
    S02BatchThing.find_each_shard(batch_size: 3) { |record| ids << record.id.not_nil! }

    ids.size.should eq 12
    ids.uniq.size.should eq 12
    ids.sort.should eq (1_i64..7_i64).to_a + (101_i64..105_i64).to_a
  end

  it "reads one shard after another, in key order within a shard" do
    ids = [] of Int64
    S02BatchThing.find_each_shard(batch_size: 2) { |record| ids << record.id.not_nil! }

    ids.should eq [1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64, 7_i64, 101_i64, 102_i64, 103_i64, 104_i64, 105_i64]
  end

  it "sets current_shard on every record" do
    shards = Hash(Int64, Symbol?).new
    S02BatchThing.find_each_shard(batch_size: 4) { |record| shards[record.id.not_nil!] = record.current_shard }

    (1_i64..7_i64).each { |id| shards[id].should eq :one }
    (101_i64..105_i64).each { |id| shards[id].should eq :two }
  end

  it "pages by keyset, never by OFFSET" do
    statements = StatementRecorder.statements do
      S02BatchThing.find_each_shard(batch_size: 3) { |_| }
    end
    selects = statements.select(&.includes?("s02_batch_things"))

    selects.should_not be_empty
    selects.each(&.upcase.should_not(contain("OFFSET")))
    selects.any?(&.matches?(/id["`]?\s*>\s*[?$]/)).should be_true
  end

  it "is what Model.find_each does on a sharded model" do
    ids = [] of Int64
    S02BatchThing.find_each(batch_size: 3) { |record| ids << record.id.not_nil! }

    ids.size.should eq 12
    ids.uniq.size.should eq 12
  end

  it "honors start and finish" do
    ids = [] of Int64
    S02BatchThing.find_each_shard(batch_size: 3, start: 3_i64, finish: 102_i64) { |record| ids << record.id.not_nil! }

    ids.should eq [3_i64, 4_i64, 5_i64, 6_i64, 7_i64, 101_i64, 102_i64]
  end

  it "iterates a filtered relation across shards without duplicates" do
    ids = [] of Int64
    S02BatchThing.where("id > ?", 5_i64).find_each(batch_size: 2) { |record| ids << record.id.not_nil! }

    ids.sort.should eq [6_i64, 7_i64, 101_i64, 102_i64, 103_i64, 104_i64, 105_i64]
    ids.uniq.size.should eq ids.size
  end

  it "iterates a single shard when the shard is fixed" do
    ids = [] of Int64
    S02BatchThing.connected_to(shard: :two) do
      S02BatchThing.all.find_each(batch_size: 2) { |record| ids << record.id.not_nil! }
    end

    ids.should eq [101_i64, 102_i64, 103_i64, 104_i64, 105_i64]
  end
end
