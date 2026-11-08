require "spec"

{% skip_file unless env("CURRENT_ADAPTER") == "pg" %}

require "../spec_helper"

module Grant::PG
  class Connection
    getter connection
  end
end

describe Grant::PQ::Connection, "#server_parameters" do
  it "ParameterStatus frames in response to set are handeled" do
    get = -> { PG_DRIVER_DB.using_connection &.connection.server_parameters["standard_conforming_strings"] }
    get.call.should eq("on")
    PG_DRIVER_DB.exec "set standard_conforming_strings to on"
    get.call.should eq("on")
    PG_DRIVER_DB.exec "set standard_conforming_strings to off"
    get.call.should eq("off")
    PG_DRIVER_DB.exec "set standard_conforming_strings to default"
    get.call.should eq("on")
  end
end

describe Grant::PQ::Connection do
  it "handles empty queries" do
    PG_DRIVER_DB.exec ""
    PG_DRIVER_DB.query("") { }
    PG_DRIVER_DB.query_one("select 1", &.read).should eq(1)
  end
end
