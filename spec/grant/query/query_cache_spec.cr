require "../../spec_helper"
require "../../support/statement_recorder"
require "../../../src/grant/middleware/query_cache"

class QueryCacheQ05Note < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table query_cache_q05_notes

  column id : Int64, primary: true
  column title : String?
  column rank : Int32?
end

private def selects_on_notes(&) : Int32
  statements = StatementRecorder.statements { yield }
  statements.count { |sql| sql.lstrip.upcase.starts_with?("SELECT") && sql.includes?("query_cache_q05_notes") }
end

describe "query cache" do
  before_each do
    QueryCacheQ05Note.migrator.drop_and_create
    QueryCacheQ05Note.create(title: "one", rank: 1)
    QueryCacheQ05Note.create(title: "two", rank: 2)
  end

  it "answers a repeated read from the cache" do
    titles = [] of Array(String?)
    count = selects_on_notes do
      Grant.cache do
        2.times { titles << QueryCacheQ05Note.order(:rank).to_a.map(&.title) }
      end
    end
    count.should eq 1
    titles.first.should eq ["one", "two"]
    titles.last.should eq titles.first
  end

  it "does nothing outside a cache block" do
    selects_on_notes do
      2.times { QueryCacheQ05Note.count }
    end.should eq 2
    Grant::QueryCache.current?.should be_nil
  end

  it "caches counts, pluck and other scalar reads" do
    selects_on_notes do
      Grant.cache do
        2.times { QueryCacheQ05Note.count.should eq 2 }
        2.times { QueryCacheQ05Note.where(rank: 1).pluck(:title).should eq [["one"]] }
        2.times { QueryCacheQ05Note.exists?(QueryCacheQ05Note.first!.id).should be_true }
      end
    end.should eq 4
  end

  it "reports cache hits as cached SQL events" do
    events = [] of Bool
    subscription = Grant::Notifications.subscribe(Grant::Events::SQL) { |event| events << event.cached? if event.sql.includes?("query_cache_q05_notes"); nil }
    begin
      Grant.cache { 2.times { QueryCacheQ05Note.count } }
    ensure
      subscription.unsubscribe
    end
    events.should eq [false, true]
  end

  it "keys entries on the bind values" do
    selects_on_notes do
      Grant.cache do
        QueryCacheQ05Note.where(rank: 1).to_a.size.should eq 1
        QueryCacheQ05Note.where(rank: 2).to_a.size.should eq 1
        QueryCacheQ05Note.where(rank: 1).to_a.size.should eq 1
      end
    end.should eq 2
  end

  it "is cleared by a write in the same fiber" do
    Grant.cache do
      QueryCacheQ05Note.count.should eq 2
      QueryCacheQ05Note.create(title: "three", rank: 3)
      QueryCacheQ05Note.count.should eq 3
      QueryCacheQ05Note.first!.update(title: "renamed")
      QueryCacheQ05Note.order(:rank).first!.title.should eq "renamed"
      QueryCacheQ05Note.where(rank: 3).delete_all
      QueryCacheQ05Note.count.should eq 2
      QueryCacheQ05Note.update_all("rank = 9")
      QueryCacheQ05Note.where(rank: 9).count.should eq 2
    end
  end

  it "is cleared by a write from another fiber and connection" do
    Grant.cache do
      QueryCacheQ05Note.count.should eq 2
      done = Channel(Nil).new
      spawn do
        QueryCacheQ05Note.create(title: "elsewhere", rank: 7)
        done.send(nil)
      end
      done.receive
      QueryCacheQ05Note.count.should eq 3
    end
  end

  it "is cleared by DDL" do
    Grant.cache do
      QueryCacheQ05Note.count.should eq 2
      QueryCacheQ05Note.exec("CREATE TABLE IF NOT EXISTS query_cache_q05_ddl_probe (id INTEGER)")
      begin
        selects_on_notes { QueryCacheQ05Note.count }.should eq 1
      ensure
        QueryCacheQ05Note.exec("DROP TABLE IF EXISTS query_cache_q05_ddl_probe")
      end
    end
  end

  it "keeps a transaction's reads apart and drops them on rollback" do
    Grant.cache do
      QueryCacheQ05Note.count.should eq 2
      QueryCacheQ05Note.transaction do
        QueryCacheQ05Note.create(title: "pending", rank: 5)
        QueryCacheQ05Note.count.should eq 3
        raise Grant::Transaction::Rollback.new
      end
      QueryCacheQ05Note.count.should eq 2
    end
  end

  it "skips the cache inside uncached" do
    count = selects_on_notes do
      Grant.cache do
        QueryCacheQ05Note.count
        Grant.uncached do
          2.times { QueryCacheQ05Note.count }
        end
        QueryCacheQ05Note.count
      end
    end
    count.should eq 3
  end

  it "does not fill the cache inside uncached and re-enables afterwards" do
    Grant.cache do
      Grant.uncached { QueryCacheQ05Note.count }
      Grant::QueryCache.current?.not_nil!.size.should eq 0
      QueryCacheQ05Note.count
      Grant::QueryCache.current?.not_nil!.size.should eq 1
      Grant::QueryCache.enabled?.should be_true
    end
  end

  it "offers Model.cache and Model.uncached" do
    selects_on_notes do
      QueryCacheQ05Note.cache do
        QueryCacheQ05Note.query_cache_enabled?.should be_true
        2.times { QueryCacheQ05Note.count }
        QueryCacheQ05Note.uncached { QueryCacheQ05Note.query_cache_enabled?.should be_false }
      end
    end.should eq 1
  end

  it "keeps at most query_cache_max_entries and evicts the least recently used" do
    previous = Grant.settings.query_cache_max_entries
    Grant.settings.query_cache_max_entries = 3
    begin
      Grant.cache do
        (1..6).each { |rank| QueryCacheQ05Note.where(rank: rank).to_a }
        Grant::QueryCache.current?.not_nil!.size.should eq 3
        selects_on_notes { QueryCacheQ05Note.where(rank: 6).to_a }.should eq 0
        selects_on_notes { QueryCacheQ05Note.where(rank: 1).to_a }.should eq 1
        Grant::QueryCache.current?.not_nil!.size.should eq 3
      end
    ensure
      Grant.settings.query_cache_max_entries = previous
    end
  end

  it "stores nothing when the size is zero" do
    previous = Grant.settings.query_cache_max_entries
    Grant.settings.query_cache_max_entries = 0
    begin
      selects_on_notes { Grant.cache { 2.times { QueryCacheQ05Note.count } } }.should eq 2
    ensure
      Grant.settings.query_cache_max_entries = previous
    end
  end

  it "returns copies so a caller cannot change what is cached" do
    Grant.cache do
      first = QueryCacheQ05Note.order(:rank).to_a
      first.first.title = "changed"
      first << first.first
      again = QueryCacheQ05Note.order(:rank).to_a
      again.size.should eq 2
      again.first.title.should eq "one"
      again.first.changed?.should be_false
      again.first.should_not be(first.first)

      values = QueryCacheQ05Note.pluck(:title)
      values << "extra"
      QueryCacheQ05Note.pluck(:title).should eq ["one", "two"]
    end
  end

  it "is local to the fiber that opened the block" do
    Grant.cache do
      QueryCacheQ05Note.count
      other = Channel(Int32).new
      spawn do
        other.send(selects_on_notes { 2.times { QueryCacheQ05Note.count } })
      end
      other.receive.should eq 2
      Grant::QueryCache.current?.not_nil!.size.should eq 1
    end
  end

  it "discards the cache when the block raises" do
    expect_raises(Exception, "boom") do
      Grant.cache do
        QueryCacheQ05Note.count
        raise "boom"
      end
    end
    Grant::QueryCache.current?.should be_nil
    Grant::QueryCache.enabled?.should be_false
  end

  it "shares one cache between nested blocks and drops it at the outermost end" do
    selects_on_notes do
      Grant.cache do
        QueryCacheQ05Note.count
        Grant.cache { QueryCacheQ05Note.count }
        Grant::QueryCache.current?.should_not be_nil
      end
    end.should eq 1
    Grant::QueryCache.current?.should be_nil
  end

  it "does not cache locking reads" do
    adapter = QueryCacheQ05Note.adapter
    runs = 0
    binds = [] of Grant::Columns::Type
    Grant.cache do
      2.times do
        Grant::QueryCache.fetch(adapter, "SELECT id FROM query_cache_q05_notes FOR UPDATE", binds, nil) { runs += 1 }
      end
      2.times do
        Grant::QueryCache.fetch(adapter, "SELECT id FROM query_cache_q05_notes", binds, nil) { runs += 1 }
      end
    end
    runs.should eq 3
  end

  describe Grant::Middleware::QueryCache do
    it "turns the cache on for the request and off afterwards" do
      seen = [] of Bool
      inner = ->(context : HTTP::Server::Context) do
        seen << Grant::QueryCache.enabled?
        2.times { QueryCacheQ05Note.count }
        seen << (Grant::QueryCache.current?.not_nil!.size == 1)
        nil
      end
      handler = Grant::Middleware::QueryCache.new
      handler.next = ->(context : HTTP::Server::Context) { inner.call(context) }
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(io))
      handler.call(context)
      seen.should eq [true, true]
      Grant::QueryCache.current?.should be_nil
    end

    it "drops the cache when the request raises" do
      handler = Grant::Middleware::QueryCache.new
      handler.next = ->(context : HTTP::Server::Context) { raise "request failed" }
      io = IO::Memory.new
      context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(io))
      expect_raises(Exception, "request failed") { handler.call(context) }
      Grant::QueryCache.current?.should be_nil
    end
  end
end
