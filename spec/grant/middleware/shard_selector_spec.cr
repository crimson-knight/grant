require "../../spec_helper"
require "../../../src/grant/middleware/shard_selector"

def c03_run_shard(selector : Grant::Middleware::ShardSelector, host : String, &block : -> T) : T forall T
  result = uninitialized T
  selector.next = HTTP::Handler::HandlerProc.new { |_| result = block.call }
  headers = HTTP::Headers{"Host" => host}
  request = HTTP::Request.new("GET", "/", headers)
  context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
  selector.call(context)
  result
end

describe Grant::Middleware::ShardSelector do
  resolver = Grant::Middleware::ShardSelector::Resolver.new do |request|
    case request.headers["Host"].split('.').first
    when "tenant_a" then :tenant_a
    when "tenant_b" then :tenant_b
    end
  end

  it "runs the request on the shard the resolver picks" do
    selector = Grant::Middleware::ShardSelector.new(resolver)
    c03_run_shard(selector, "tenant_a.example.com") { Grant::Base.current_shard }.should eq :tenant_a
    c03_run_shard(selector, "tenant_b.example.com") { Grant::Base.current_shard }.should eq :tenant_b
  end

  it "leaves the request on the default shard when the resolver returns nil" do
    selector = Grant::Middleware::ShardSelector.new(resolver)
    c03_run_shard(selector, "www.example.com") { Grant::Base.current_shard }.should be_nil
  end

  it "locks the shard by default with prohibit_shard_swapping" do
    selector = Grant::Middleware::ShardSelector.new(resolver)
    c03_run_shard(selector, "tenant_a.example.com") { Grant::Base.shard_swapping_prohibited? }.should be_true
    expect_raises(Grant::ShardSwappingProhibited) do
      c03_run_shard(selector, "tenant_a.example.com") { Grant::Base.connected_to(shard: :tenant_b) { } }
    end
  end

  it "allows swapping when lock is false" do
    selector = Grant::Middleware::ShardSelector.new(resolver, lock: false)
    c03_run_shard(selector, "tenant_a.example.com") do
      Grant::Base.shard_swapping_prohibited? ? :locked : Grant::Base.connected_to(shard: :tenant_b) { Grant::Base.current_shard }
    end.should eq :tenant_b
  end

  it "restores shard and lock after the request, even when it raises" do
    selector = Grant::Middleware::ShardSelector.new(resolver)
    expect_raises(Exception, "boom") do
      c03_run_shard(selector, "tenant_a.example.com") { raise "boom"; 1 }
    end
    Grant::Base.current_shard.should be_nil
    Grant::Base.shard_swapping_prohibited?.should be_false
  end
end
