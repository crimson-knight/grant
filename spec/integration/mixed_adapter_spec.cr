require "../spec_helper"
require "file_utils"

# One process, two engines: a local SQLite file and a PostgreSQL server, each
# behind its own connection name and driven by its own model.
C03_MIXED_DIR = File.join(Dir.tempdir, "c03_mixed_#{Process.pid}")
C03_MIXED_PG  = ENV["PG_DATABASE_URL"]?

class C03LocalNote < Grant::Base
  connects_to database: "c03_local"
  table c03_mixed_notes
  column id : Int64, primary: true
  column label : String
  column amount : Int64?
end

class C03ServerNote < Grant::Base
  connects_to database: "c03_server"
  table c03_mixed_notes
  column id : Int64, primary: true
  column label : String
  column amount : Int64?
end

# Collects the statements each connection ran, keyed by connection name.
def c03_capture_sql(&) : Hash(String, Array(String))
  seen = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
  subscription = Grant::Notifications.subscribe(Grant::Events::SQL) do |event|
    seen[event.connection] << event.sql
  end
  begin
    yield
  ensure
    subscription.unsubscribe
  end
  seen
end

describe "SQLite and PostgreSQL in one process" do
  if C03_MIXED_PG.nil?
    pending "needs PG_DATABASE_URL"
  else
    before_all do
      Dir.mkdir_p(C03_MIXED_DIR)
      Grant::ConnectionRegistry.establish_connection(
        database: "c03_local", url: "sqlite3:#{File.join(C03_MIXED_DIR, "local.sqlite3")}", role: :writing)
      Grant::ConnectionRegistry.establish_connection(
        database: "c03_server", url: C03_MIXED_PG.not_nil!, role: :writing)

      C03LocalNote.adapter.open do |db|
        db.exec "DROP TABLE IF EXISTS c03_mixed_notes"
        db.exec "CREATE TABLE c03_mixed_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT NOT NULL, amount BIGINT)"
      end
      C03ServerNote.adapter.open do |db|
        db.exec "DROP TABLE IF EXISTS c03_mixed_notes"
        db.exec "CREATE TABLE c03_mixed_notes (id BIGSERIAL PRIMARY KEY, label TEXT NOT NULL, amount BIGINT)"
      end
    end

    before_each do
      C03LocalNote.adapter.open(&.exec("DELETE FROM c03_mixed_notes"))
      C03ServerNote.adapter.open(&.exec("DELETE FROM c03_mixed_notes"))
    end

    after_all do
      C03ServerNote.adapter.open { |db| db.exec "DROP TABLE IF EXISTS c03_mixed_notes" }
      Grant::ConnectionRegistry.remove_connection("c03_local", :writing)
      Grant::ConnectionRegistry.remove_connection("c03_server", :writing)
      FileUtils.rm_rf(C03_MIXED_DIR)
    end

    it "infers a different adapter for each connection from its URL" do
      C03LocalNote.adapter.should be_a Grant::Adapter::Sqlite
      C03ServerNote.adapter.should be_a Grant::Adapter::Pg
    end

    it "does create, read, update and destroy on both engines" do
      local = C03LocalNote.create!(label: "on the device", amount: 5_i64)
      server = C03ServerNote.create!(label: "on the server", amount: 9_i64)

      C03LocalNote.find!(local.id).label.should eq "on the device"
      C03ServerNote.find!(server.id).label.should eq "on the server"

      local.update!(amount: 6_i64)
      server.update!(amount: 10_i64)
      C03LocalNote.find!(local.id).amount.should eq 6_i64
      C03ServerNote.find!(server.id).amount.should eq 10_i64

      local.destroy
      server.destroy
      C03LocalNote.count.should eq 0
      C03ServerNote.count.should eq 0
    end

    it "keeps the rows of each engine separate" do
      C03LocalNote.create!(label: "local only")
      C03ServerNote.create!(label: "server only")

      C03LocalNote.all.map(&.label).should eq ["local only"]
      C03ServerNote.all.map(&.label).should eq ["server only"]
    end

    it "uses each engine's own placeholders and never leaks one into the other" do
      seen = c03_capture_sql do
        C03LocalNote.create!(label: "alpha", amount: 1_i64)
        C03ServerNote.create!(label: "alpha", amount: 1_i64)
        C03LocalNote.where(label: "alpha").select.size.should eq 1
        C03ServerNote.where(label: "alpha").select.size.should eq 1
        C03LocalNote.where("amount > ?", 0_i64).select.size.should eq 1
        C03ServerNote.where("amount > ?", 0_i64).select.size.should eq 1
      end

      local_sql = seen[C03LocalNote.adapter.name].select(&.includes?("c03_mixed_notes"))
      server_sql = seen[C03ServerNote.adapter.name].select(&.includes?("c03_mixed_notes"))
      local_sql.should_not be_empty
      server_sql.should_not be_empty
      local_sql.each(&.should_not(match(/\$\d/)))
      server_sql.each(&.should_not(contain("?")))
      server_sql.any?(&.match(/\$\d/)).should be_true
    end

    it "runs transactions on each engine independently" do
      C03LocalNote.transaction do
        C03LocalNote.create!(label: "local committed")
        C03LocalNote.transaction_open?.should be_true
      end
      expect_raises(Exception, "abort server") do
        C03ServerNote.transaction do
          C03ServerNote.create!(label: "server rolled back")
          raise "abort server"
        end
      end

      C03LocalNote.all.map(&.label).should eq ["local committed"]
      C03ServerNote.count.should eq 0
    end

    it "does not pin the other engine: a transaction on one commits or rolls back without touching the other" do
      expect_raises(Exception, "local abort") do
        C03LocalNote.transaction do
          C03LocalNote.create!(label: "local rolled back")
          # A write on the other engine inside the open local transaction runs
          # on its own connection and commits on its own.
          C03ServerNote.create!(label: "server survives")
          raise "local abort"
        end
      end

      C03LocalNote.count.should eq 0
      C03ServerNote.all.map(&.label).should eq ["server survives"]

      C03ServerNote.transaction do
        C03ServerNote.create!(label: "server in tx")
        C03LocalNote.create!(label: "local survives")
        raise Grant::Transaction::Rollback.new
      end
      C03ServerNote.all.map(&.label).should eq ["server survives"]
      C03LocalNote.all.map(&.label).should eq ["local survives"]
    end

    it "handles typed values on both engines without cross-engine type leakage" do
      big = 9_000_000_000_i64
      C03LocalNote.create!(label: "big", amount: big)
      C03ServerNote.create!(label: "big", amount: big)
      C03LocalNote.first!.amount.should eq big
      C03ServerNote.first!.amount.should eq big
      C03LocalNote.create!(label: "nil amount")
      C03ServerNote.create!(label: "nil amount")
      C03LocalNote.where(label: "nil amount").first!.amount.should be_nil
      C03ServerNote.where(label: "nil amount").first!.amount.should be_nil
    end
  end
end
