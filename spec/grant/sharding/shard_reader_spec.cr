require "../../spec_helper"
require "../../support/real_sqlite_shards"

# Each shard has a writer file and a reader file. The reader rows differ from
# the writer rows, so what a query returns names the file it came from.
class S02ReplicaThing < Grant::Base
  connection "s02_replicas"
  table s02_replica_things
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column label : String
end

S02_REPLICA_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_replicas", [:one, :two],
  ["CREATE TABLE s02_replica_things (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, label TEXT NOT NULL)"],
  readers: true
)

def s02_replica_labels(fixture : Grant::Testing::RealSqliteShards, shard : Symbol, reader : Bool) : Array(String)
  labels = [] of String
  DB.open("sqlite3:#{fixture.path_for(shard, reader)}") do |db|
    db.query("SELECT label FROM s02_replica_things ORDER BY id") { |rs| rs.each { labels << rs.read(String) } }
  end
  labels
end

describe "Per-shard read replicas" do
  before_all do
    S02_REPLICA_FIXTURE.set_up
    S02_REPLICA_FIXTURE.exec(:one, "INSERT INTO s02_replica_things (id, tenant_id, label) VALUES (1, 1, 'one writer')")
    S02_REPLICA_FIXTURE.exec(:one, "INSERT INTO s02_replica_things (id, tenant_id, label) VALUES (1, 1, 'one reader')", reader: true)
    S02_REPLICA_FIXTURE.exec(:two, "INSERT INTO s02_replica_things (id, tenant_id, label) VALUES (2, 2, 'two writer')")
    S02_REPLICA_FIXTURE.exec(:two, "INSERT INTO s02_replica_things (id, tenant_id, label) VALUES (2, 2, 'two reader')", reader: true)
  end

  after_all do
    S02_REPLICA_FIXTURE.tear_down
  end

  it "reads the shard writer by default" do
    S02ReplicaThing.connected_to(shard: :one) { S02ReplicaThing.first!.label }.should eq "one writer"
    S02ReplicaThing.connected_to(shard: :two) { S02ReplicaThing.first!.label }.should eq "two writer"
  end

  it "reads the shard reader inside connected_to(role: :reading, shard:)" do
    S02ReplicaThing.connected_to(role: :reading, shard: :one) { S02ReplicaThing.first!.label }.should eq "one reader"
    S02ReplicaThing.connected_to(role: :reading, shard: :two) { S02ReplicaThing.first!.label }.should eq "two reader"
  end

  it "resolves the shard reader adapter" do
    S02ReplicaThing.connected_to(role: :reading, shard: :one) { S02ReplicaThing.adapter.url }.should contain "one_reader.sqlite3"
    S02ReplicaThing.connected_to(role: :writing, shard: :one) { S02ReplicaThing.adapter.url }.should contain "one.sqlite3"
  end

  it "reads every shard reader when a scatter query runs in the reading role" do
    labels = S02ReplicaThing.connected_to(role: :reading) do
      S02ReplicaThing.order(id: :asc).select.map(&.label)
    end

    labels.should eq ["one reader", "two reader"]
  end

  it "aggregates from the shard readers in the reading role" do
    S02ReplicaThing.connected_to(role: :reading) { S02ReplicaThing.count }.should eq 2_i64
    S02ReplicaThing.connected_to(role: :reading) { S02ReplicaThing.max(:id) }.should eq 2_i64
  end

  it "refuses a write in the reading role and leaves every file alone" do
    expect_raises(Grant::Transaction::ReadOnlyError) do
      S02ReplicaThing.connected_to(role: :reading, shard: :one) do
        S02ReplicaThing.new(tenant_id: 1_i64, label: "refused").save!
      end
    end

    s02_replica_labels(S02_REPLICA_FIXTURE, :one, false).should eq ["one writer"]
    s02_replica_labels(S02_REPLICA_FIXTURE, :one, true).should eq ["one reader"]
  end

  it "sends writes to the shard writer, never its reader" do
    S02ReplicaThing.new(tenant_id: 2_i64, label: "written").save!

    s02_replica_labels(S02_REPLICA_FIXTURE, :two, false).should contain "written"
    s02_replica_labels(S02_REPLICA_FIXTURE, :two, true).should eq ["two reader"]
  end
end
