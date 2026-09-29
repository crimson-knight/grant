require "../../spec_helper"
require "../../../src/grant/middleware/database_selector"

# Records what the downstream handler saw for one request.
struct C03Observed
  getter role : Symbol
  getter preventing_writes : Bool

  def initialize(@role, @preventing_writes)
  end
end

class C03SelectorClock
  property now : Time = Time.utc(2026, 9, 29, 12, 0, 0)
end

def c03_run_selector(selector : Grant::Middleware::DatabaseSelector, method : String,
                     cookie : String? = nil) : {C03Observed, HTTP::Server::Context}
  observed = nil
  selector.next = HTTP::Handler::HandlerProc.new do |_|
    observed = C03Observed.new(Grant::Base.current_role, Grant::Base.preventing_writes?)
  end
  headers = HTTP::Headers.new
  headers["Cookie"] = cookie if cookie
  request = HTTP::Request.new(method, "/things", headers)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
  selector.call(context)
  {observed.not_nil!, context}
end

def c03_cookie_of(context : HTTP::Server::Context) : String
  cookie = context.response.cookies["grant_last_write"]
  "grant_last_write=#{cookie.value}"
end

describe Grant::Middleware::DatabaseSelector do
  clock = C03SelectorClock.new
  store = Grant::Middleware::DatabaseSelector::CookieStore.new(secret: "s3cret-for-specs")
  selector = Grant::Middleware::DatabaseSelector.new(store, clock: -> { clock.now })

  before_each { clock.now = Time.utc(2026, 9, 29, 12, 0, 0) }

  it "reads GET and HEAD requests from the reading role, which prevents writes" do
    {"GET", "HEAD"}.each do |verb|
      observed, _ = c03_run_selector(selector, verb)
      observed.role.should eq :reading
      observed.preventing_writes.should be_true
    end
  end

  it "sends every write verb to the writing role" do
    {"POST", "PUT", "PATCH", "DELETE"}.each do |verb|
      observed, _ = c03_run_selector(selector, verb)
      observed.role.should eq :writing
      observed.preventing_writes.should be_false
    end
  end

  it "stores the write timestamp only after a write request" do
    _, get_context = c03_run_selector(selector, "GET")
    get_context.response.cookies["grant_last_write"]?.should be_nil

    _, head_context = c03_run_selector(selector, "HEAD")
    head_context.response.cookies["grant_last_write"]?.should be_nil

    _, post_context = c03_run_selector(selector, "POST")
    post_context.response.cookies["grant_last_write"]?.should_not be_nil
  end

  it "keeps a client on the writing role for the delay after its write, then returns to reading" do
    _, post_context = c03_run_selector(selector, "POST")
    cookie = c03_cookie_of(post_context)

    clock.now += 1.second
    observed, _ = c03_run_selector(selector, "GET", cookie)
    observed.role.should eq :writing

    clock.now += 1.5.seconds # 2.5s since the write
    observed, _ = c03_run_selector(selector, "GET", cookie)
    observed.role.should eq :reading
  end

  it "honors a custom delay" do
    slow = Grant::Middleware::DatabaseSelector.new(store, delay: 10.seconds, clock: -> { clock.now })
    _, post_context = c03_run_selector(slow, "POST")
    cookie = c03_cookie_of(post_context)

    clock.now += 5.seconds
    c03_run_selector(slow, "GET", cookie)[0].role.should eq :writing
    clock.now += 6.seconds
    c03_run_selector(slow, "GET", cookie)[0].role.should eq :reading
  end

  it "ignores a forged or malformed cookie" do
    c03_run_selector(selector, "GET", "grant_last_write=#{clock.now.to_unix_ms}.deadbeef")[0].role.should eq :reading
    c03_run_selector(selector, "GET", "grant_last_write=garbage")[0].role.should eq :reading
  end

  it "lets a resolver choose the role from the request and the last write" do
    seen = nil
    resolver = Grant::Middleware::DatabaseSelector::Resolver.new do |request, last_write|
      seen = last_write
      request.path == "/things" ? :reading : :writing
    end
    custom = Grant::Middleware::DatabaseSelector.new(store, resolver: resolver, clock: -> { clock.now })
    c03_run_selector(custom, "POST")[0].role.should eq :reading
    seen.should be_nil
  end

  it "supports a store backed by the app's own session" do
    written = nil
    proc_store = Grant::Middleware::DatabaseSelector::ProcStore.new(
      ->(_request : HTTP::Request) { written },
      ->(_context : HTTP::Server::Context, time : Time) { written = time; nil })
    session = Grant::Middleware::DatabaseSelector.new(proc_store, clock: -> { clock.now })

    c03_run_selector(session, "GET")[0].role.should eq :reading
    c03_run_selector(session, "POST")
    c03_run_selector(session, "GET")[0].role.should eq :writing
  end

  it "restores the previous connection context after the request" do
    c03_run_selector(selector, "GET")
    Grant::Base.current_role.should_not eq :reading
    Grant::Base.preventing_writes?.should be_false
  end

  it "restores the context when the downstream handler raises" do
    selector.next = HTTP::Handler::HandlerProc.new { |_| raise "boom" }
    request = HTTP::Request.new("GET", "/things")
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
    expect_raises(Exception, "boom") { selector.call(context) }
    Grant::Base.preventing_writes?.should be_false
  end
end
