require "../../spec_helper"
require "file_utils"

# Two SQLite files stand in for a writer and a replica. The rows differ per
# file, so what a query returns identifies the adapter Grant actually chose.
C01_ROUTE_DIR  = File.join(Dir.tempdir, "c01_route_#{Process.pid}")
C01_ROUTE_W    = File.join(C01_ROUTE_DIR, "writer.sqlite3")
C01_ROUTE_R    = File.join(C01_ROUTE_DIR, "reader.sqlite3")
C01_ROUTE_NAME = "c01_route"

class C01RoutedRecord < Grant::Base
  table c01_routed_records
  column id : Int64, primary: true
  column label : String?
  connects_to database: {writing: "c01_route_writer", reading: "c01_route_reader"}
end

# Reads a file directly, bypassing Grant's routing.
def c01_labels(path : String) : Array(String)
  labels = [] of String
  DB.open("sqlite3:#{path}") do |db|
    db.query("SELECT label FROM c01_routed_records ORDER BY id") { |rs| rs.each { labels << rs.read(String) } }
  end
  labels
end

describe "role routing across two SQLite files" do
  before_all do
    Dir.mkdir_p(C01_ROUTE_DIR)
    {C01_ROUTE_W, C01_ROUTE_R}.each do |path|
      File.delete?(path)
      DB.open("sqlite3:#{path}") do |db|
        db.exec "CREATE TABLE c01_routed_records (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)"
      end
    end
    DB.open("sqlite3:#{C01_ROUTE_W}") { |db| db.exec "INSERT INTO c01_routed_records (label) VALUES ('writer row')" }
    DB.open("sqlite3:#{C01_ROUTE_R}") { |db| db.exec "INSERT INTO c01_routed_records (label) VALUES ('reader row')" }

    Grant::ConnectionRegistry.establish_connection(
      database: "c01_route_writer", adapter: Grant::Adapter::Sqlite,
      url: "sqlite3:#{C01_ROUTE_W}", role: :writing)
    Grant::ConnectionRegistry.establish_connection(
      database: "c01_route_reader", adapter: Grant::Adapter::Sqlite,
      url: "sqlite3:#{C01_ROUTE_R}", role: :reading)
  end

  after_all do
    # Remove only this file's connections: clear_all would also drop the
    # default spec connections, and the next file's before_all runs before any
    # before_each can restore them.
    Grant::ConnectionRegistry.remove_connection("c01_route_writer", :writing)
    Grant::ConnectionRegistry.remove_connection("c01_route_reader", :reading)
    FileUtils.rm_rf(C01_ROUTE_DIR)
  end

  it "resolves the reading role to the reader file and the writing role to the writer file" do
    C01RoutedRecord.connected_to(role: :reading) { C01RoutedRecord.adapter.url }.should contain "reader.sqlite3"
    C01RoutedRecord.connected_to(role: :writing) { C01RoutedRecord.adapter.url }.should contain "writer.sqlite3"
    C01RoutedRecord.connected_to(role: :primary) { C01RoutedRecord.adapter.url }.should contain "writer.sqlite3"
  end

  it "returns different rows for each role, which only the right file can produce" do
    C01RoutedRecord.connected_to(role: :reading) { C01RoutedRecord.first!.label }.should eq "reader row"
    C01RoutedRecord.connected_to(role: :writing) { C01RoutedRecord.first!.label }.should eq "writer row"
    C01RoutedRecord.connected_to(role: :primary) { C01RoutedRecord.first!.label }.should eq "writer row"
  end

  it "sends writes to the writer file, never the reader file" do
    C01RoutedRecord.create!(label: "written")

    c01_labels(C01_ROUTE_W).should contain "written"
    c01_labels(C01_ROUTE_R).should eq ["reader row"]
  end

  it "refuses a write attempted in the reading role and leaves both files alone" do
    before_writer = c01_labels(C01_ROUTE_W)

    expect_raises(Grant::Transaction::ReadOnlyError) do
      C01RoutedRecord.connected_to(role: :reading) { C01RoutedRecord.create!(label: "refused") }
    end

    c01_labels(C01_ROUTE_W).should eq before_writer
    c01_labels(C01_ROUTE_R).should eq ["reader row"]
  end

  it "reads from the writer while stuck to the primary after a write" do
    C01RoutedRecord.create!(label: "sticky")
    C01RoutedRecord.stick_to_primary(30.seconds)

    C01RoutedRecord.current_role.should eq :primary
    C01RoutedRecord.adapter.url.should contain "writer.sqlite3"
  end
end
