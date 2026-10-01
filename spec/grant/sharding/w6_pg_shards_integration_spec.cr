require "../../spec_helper"
require "../../support/w6_c04_support"
require "../../../src/grant/sharding"

# Four shard databases, each a real PostgreSQL database (or SQLite file when
# the SQLite adapter runs the spec). Three models with three strategies place
# their rows on the same shards.
class W6IntHashAccount < Grant::Base
  include Grant::Sharding::Model

  connection "w6_int_hash"
  table w6_int_hash_accounts
  column id : Int64, primary: true
  column account_id : Int64
  column label : String?

  shards_by :account_id, strategy: :hash, count: 4
end

class W6IntLookupAccount < Grant::Base
  include Grant::Sharding::Model

  connection "w6_int_lookup"
  table w6_int_lookup_accounts
  column id : Int64, primary: true
  column account_id : Int64
  column label : String?

  shards_by :account_id, strategy: :lookup, lookup: {"1" => :shard_0, "2" => :shard_1}, default_shard: nil
end

class W6IntRangeAccount < Grant::Base
  include Grant::Sharding::Model

  connection "w6_int_range"
  table w6_int_range_accounts
  column id : Int64, primary: true
  column account_id : Int64
  column label : String?

  shards_by :account_id, strategy: :range, ranges: [
    {min: 1_i64, max: 100_i64, shard: :shard_0},
    {min: 101_i64, max: 200_i64, shard: :shard_1},
  ]
end

W6_INT_SHARDS = [:shard_0, :shard_1, :shard_2, :shard_3]

private def w6_int_db(shard : Symbol) : String
  "w6_int_#{shard}"
end

private def w6_int_ids(shard : Symbol, table : String = "w6_int_hash_accounts") : Array(String)
  W6C04.strings(w6_int_db(shard), "SELECT CAST(account_id AS TEXT) FROM #{table} ORDER BY account_id")
end

describe "sharding integration on #{CURRENT_ADAPTER}" do
  before_all do
    ddl = %w(w6_int_hash_accounts w6_int_lookup_accounts w6_int_range_accounts).map do |table|
      "CREATE TABLE #{table} (#{W6C04.id_column}, account_id BIGINT NOT NULL, label TEXT)"
    end
    W6_INT_SHARDS.each do |shard|
      W6C04.provision(w6_int_db(shard), ddl)
      {"w6_int_hash", "w6_int_lookup", "w6_int_range"}.each do |database|
        W6C04.establish(database, w6_int_db(shard), :primary, shard)
      end
    end
  end

  after_all do
    W6_INT_SHARDS.each do |shard|
      {"w6_int_hash", "w6_int_lookup", "w6_int_range"}.each { |database| W6C04.remove(database, :primary, shard) }
    end
    W6C04.cleanup
  end

  describe "restart-stable hashing on real data" do
    it "places rows on the shards pinned by the hash, which no restart changes" do
      {1_i64 => :shard_0, 2_i64 => :shard_3, 42_i64 => :shard_3}.each do |account, shard|
        W6IntHashAccount.new(account_id: account, label: "account #{account}").save!
        w6_int_ids(shard).should contain account.to_s
      end
      w6_int_ids(:shard_1).should be_empty
      w6_int_ids(:shard_2).should be_empty
    end

    it "finds the rows through a resolver built again, as after a restart" do
      W6IntHashAccount.sharding_config = Grant::Sharding::ShardConfig.new([:account_id], Grant::Sharding::HashResolver.new([:account_id], 4))
      Grant::ShardManager.register("W6IntHashAccount", W6IntHashAccount.sharding_config.not_nil!)

      {1_i64, 2_i64, 42_i64}.each do |account|
        W6IntHashAccount.where(account_id: account).first!.label.should eq "account #{account}"
      end
      W6IntHashAccount.count.should eq 3
    end
  end

  describe "across strategies" do
    it "routes each model by its own strategy to the shards that hold its rows" do
      W6IntLookupAccount.new(account_id: 1_i64, label: "lookup one").save!
      W6IntLookupAccount.new(account_id: 2_i64, label: "lookup two").save!
      W6IntRangeAccount.new(account_id: 50_i64, label: "range low").save!
      W6IntRangeAccount.new(account_id: 150_i64, label: "range high").save!

      w6_int_ids(:shard_0, "w6_int_lookup_accounts").should eq ["1"]
      w6_int_ids(:shard_1, "w6_int_lookup_accounts").should eq ["2"]
      w6_int_ids(:shard_0, "w6_int_range_accounts").should eq ["50"]
      w6_int_ids(:shard_1, "w6_int_range_accounts").should eq ["150"]
    end

    it "reads them back through shard-key queries and scatter queries" do
      W6IntLookupAccount.where(account_id: 2_i64).first!.label.should eq "lookup two"
      W6IntRangeAccount.where(account_id: 150_i64).first!.label.should eq "range high"
      W6IntRangeAccount.where(:account_id, :gteq, 100_i64).select.map(&.label).should eq ["range high"]
      W6IntLookupAccount.order(account_id: :asc).select.map(&.label).should eq ["lookup one", "lookup two"]
      W6IntRangeAccount.count.should eq 2_i64
    end
  end

  describe "errors" do
    it "raises a Grant error for a key no shard serves" do
      expect_raises(Grant::Sharding::ShardNotFoundError) { W6IntRangeAccount.new(account_id: 500_i64, label: "none").save! }
      W6IntRangeAccount.count.should eq 2_i64
    end

    it "raises when the shard key is missing" do
      expect_raises(Grant::Sharding::ShardKeyMissingError) { Grant::ShardManager.resolve_shard("W6IntHashAccount") }
    end

    it "raises for a shard whose connection was never established, naming it, and writes nothing" do
      Grant::ConnectionRegistry.remove_connection("w6_int_range", :primary, :shard_1)
      begin
        expect_raises(Grant::AdapterNotAvailableError, /shard_1/) { W6IntRangeAccount.new(account_id: 160_i64, label: "lost").save! }
        # A scatter query fails as a whole instead of returning a partial answer.
        expect_raises(Grant::AdapterNotAvailableError) { W6IntRangeAccount.count }
      ensure
        W6C04.establish("w6_int_range", w6_int_db(:shard_1), :primary, :shard_1)
      end
      w6_int_ids(:shard_1, "w6_int_range_accounts").should eq ["150"]
    end
  end

  describe "transactions" do
    it "commits and rolls back atomically on one shard" do
      Grant::ShardManager.with_shard(:shard_0) do
        expect_raises(Exception, "abort") do
          W6IntHashAccount.transaction do
            W6IntHashAccount.new(account_id: 1000_i64, label: "tx a").tap { |record| record.current_shard = :shard_0 }.save!
            W6IntHashAccount.new(account_id: 1001_i64, label: "tx b").tap { |record| record.current_shard = :shard_0 }.save!
            raise "abort"
          end
        end
      end
      W6C04.strings(w6_int_db(:shard_0), "SELECT label FROM w6_int_hash_accounts WHERE label LIKE 'tx %'").should be_empty

      Grant::ShardManager.with_shard(:shard_0) do
        W6IntHashAccount.transaction do
          W6IntHashAccount.new(account_id: 1000_i64, label: "tx kept").tap { |record| record.current_shard = :shard_0 }.save!
        end
      end
      W6C04.strings(w6_int_db(:shard_0), "SELECT label FROM w6_int_hash_accounts WHERE label LIKE 'tx %'").should eq ["tx kept"]
    end

    it "covers only the shard it runs on: a record of another shard commits on its own" do
      expect_raises(Exception, "abort") do
        Grant::ShardManager.with_shard(:shard_0) do
          W6IntHashAccount.transaction do
            W6IntHashAccount.new(account_id: 1_i64, label: "own shard, rolled back").save!
            # account 2 hashes to shard_3, a different database: not part of the transaction.
            W6IntHashAccount.new(account_id: 2_i64, label: "other shard, committed").save!
            raise "abort"
          end
        end
      end

      W6C04.strings(w6_int_db(:shard_0), "SELECT label FROM w6_int_hash_accounts WHERE label LIKE 'own shard%'").should be_empty
      W6C04.strings(w6_int_db(:shard_3), "SELECT label FROM w6_int_hash_accounts WHERE label LIKE 'other shard%'").should eq ["other shard, committed"]
    end

    it "needs a shard to run on" do
      expect_raises(Exception, /No shard context/) { W6IntHashAccount.transaction { } }
    end
  end

  describe "concurrent writers" do
    it "keeps every row of fibers writing to all shards at once, each on its own shard" do
      done = Channel(Nil).new
      writers = 6
      per_writer = 20
      writers.times do |writer|
        spawn do
          per_writer.times do |n|
            account = 10_000_i64 + writer * 100 + n
            W6IntHashAccount.new(account_id: account, label: "concurrent").save!
          end
        ensure
          done.send(nil)
        end
      end
      writers.times { done.receive }

      resolver = W6IntHashAccount.sharding_config.not_nil!.resolver
      total = 0
      W6_INT_SHARDS.each do |shard|
        rows = W6C04.strings(w6_int_db(shard), "SELECT account_id FROM w6_int_hash_accounts WHERE label = 'concurrent' ORDER BY account_id")
        rows.each { |account| resolver.resolve_for_values([account.to_i64]).should eq shard }
        total += rows.size
      end
      total.should eq writers * per_writer
      W6IntHashAccount.where(label: "concurrent").count.should eq (writers * per_writer).to_i64
    end

    it "keeps concurrent scatter reads consistent while writers run" do
      done = Channel(Int64).new
      4.times { spawn { done.send(W6IntHashAccount.where(label: "concurrent").count.as(Int64)) } }
      4.times { done.receive.should eq 120_i64 }
    end
  end
end
