require "../../spec_helper"
require "../../support/w6_c04_support"

# Connection failures raised by real connection attempts, not by translating
# a hand-built driver exception.
class W6NoDbThing < Grant::Base
  table w6_no_db_things
  column id : Int64, primary: true
  column label : String?
end

private def w6_missing_url : String
  W6C04.pg? ? W6C04.pg_url("grant_w6_c04_does_not_exist") : "sqlite3:/w6_c04_no_such_directory/missing.sqlite3"
end

private def w6_refused_url : String
  W6C04.pg? ? "postgres://localhost:1/w6_refused" : "postgres://localhost:1/w6_refused"
end

describe "connection errors from live attempts (#{CURRENT_ADAPTER})" do
  after_each do
    Grant::ConnectionRegistry.remove_connection("w6_no_db", :writing)
    Grant::ConnectionRegistry.remove_connection("w6_refused", :writing)
  end

  after_all { W6C04.cleanup }

  it "raises NoDatabaseError for a database that does not exist" do
    adapter = W6C04.adapter_class.new("w6_no_db", w6_missing_url)

    error = expect_raises(Grant::NoDatabaseError) { adapter.open("SELECT 1") { |db| db.scalar("SELECT 1") } }
    error.cause.should_not be_nil
    error.message.to_s.should contain "w6_no_db"
  end

  it "raises NoDatabaseError through a model on a registered connection" do
    Grant::ConnectionRegistry.establish_connection(
      database: "w6_no_db", adapter: W6C04.adapter_class, url: w6_missing_url, role: :writing, pool_size: 2, initial_pool_size: 0)

    expect_raises(Grant::NoDatabaseError) do
      W6NoDbThing.connected_to(database: "w6_no_db") { W6NoDbThing.count }
    end
  end

  it "reports a missing database from verify! and active?" do
    adapter = W6C04.adapter_class.new("w6_no_db", w6_missing_url)

    expect_raises(Grant::NoDatabaseError) { adapter.verify! }
    adapter.active?.should be_false
  end

  it "raises ConnectionFailed for a server that refuses the connection" do
    adapter = Grant::Adapter::Pg.new("w6_refused", w6_refused_url)

    error = expect_raises(Grant::ConnectionFailed) { adapter.open("SELECT 1") { |db| db.scalar("SELECT 1") } }
    error.should be_a(Grant::ConnectionNotEstablished)
    error.cause.should be_a(DB::ConnectionRefused)
    expect_raises(Grant::ConnectionFailed) { adapter.verify! }
    adapter.active?.should be_false
  end

  it "does not mistake a refused connection for a missing database" do
    adapter = Grant::Adapter::Pg.new("w6_refused", w6_refused_url)

    error = expect_raises(Grant::ConnectionFailed) { adapter.open { |db| db.scalar("SELECT 1") } }
    error.should_not be_a(Grant::NoDatabaseError)
  end

  it "raises ConnectionTimeoutError when no pooled connection frees up in time" do
    url = W6C04.provision("w6_no_db_pool", ["CREATE TABLE w6_no_db_things (#{W6C04.id_column}, label TEXT)"])
    Grant::ConnectionRegistry.establish_connection(
      database: "w6_no_db", adapter: W6C04.adapter_class, url: url, role: :writing,
      pool_size: 1, initial_pool_size: 1, checkout_timeout: 100.milliseconds, retry_attempts: 0)
    adapter = Grant::ConnectionRegistry.get_adapter("w6_no_db", :writing)

    adapter.with_connection do |_held|
      other = Channel(Exception?).new
      spawn do
        begin
          # A second fiber needs a connection while the first holds the only one.
          adapter.open_pool_connection { |connection| connection.scalar("SELECT 1") }
          other.send(nil)
        rescue ex
          other.send(ex)
        end
      end
      other.receive.should be_a(Grant::ConnectionTimeoutError)
    end
  end
end
