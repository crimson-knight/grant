require "../../spec_helper"
require "../../../src/grant/middleware/database_selector"

class C03SelectorAnalyticsModel < Grant::Base
  connects_to database: "c03_selector_analytics"
  table c03_selector_analytics_models
  column id : Int64, primary: true
end

describe Grant::Middleware::DatabaseSelector do
  it "switches the role of every model while each model keeps its own database" do
    store = Grant::Middleware::DatabaseSelector::CookieStore.new(secret: "s3cret-for-databases-spec")
    selector = Grant::Middleware::DatabaseSelector.new(store)
    seen = [] of {String, Symbol, Bool}
    selector.next = HTTP::Handler::HandlerProc.new do |_|
      seen << {C03SelectorAnalyticsModel.current_database, C03SelectorAnalyticsModel.current_role,
               C03SelectorAnalyticsModel.preventing_writes?}
    end
    context = HTTP::Server::Context.new(HTTP::Request.new("GET", "/"),
      HTTP::Server::Response.new(IO::Memory.new))
    selector.call(context)
    seen.should eq [{"c03_selector_analytics", :reading, true}]
  end

  it "applies an explicit database only when one is given" do
    Grant::Base.connected_to(database: "c03_selector_elsewhere") do
      Grant::Base.connected_to(role: :reading) do
        C03SelectorAnalyticsModel.current_database.should eq "c03_selector_elsewhere"
      end
    end
    C03SelectorAnalyticsModel.connected_to(database: "c03_selector_elsewhere") do
      Grant::Base.connected_to(role: :reading) do
        C03SelectorAnalyticsModel.current_database.should eq "c03_selector_elsewhere"
        C03SelectorAnalyticsModel.current_role.should eq :reading
      end
    end
  end
end

describe "Grant::Middleware::DatabaseSelector role names" do
  it "defaults to the roles named in Grant.settings" do
    previous = Grant.settings.reading_role
    Grant.settings.reading_role = :c03_replica
    begin
      selector = Grant::Middleware::DatabaseSelector.new(
        Grant::Middleware::DatabaseSelector::CookieStore.new(secret: "s3cret-for-role-names"))
      seen = [] of {Symbol, Bool}
      selector.next = HTTP::Handler::HandlerProc.new { |_| seen << {Grant::Base.current_role, Grant::Base.preventing_writes?} }
      selector.call(HTTP::Server::Context.new(HTTP::Request.new("GET", "/"),
        HTTP::Server::Response.new(IO::Memory.new)))
      seen.should eq [{:c03_replica, true}]
    ensure
      Grant.settings.reading_role = previous
    end
  end
end
