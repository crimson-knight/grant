require "./pool_spec_support"

# An adapter whose health probe fails on demand.
class C02FailoverAdapter < Grant::Adapter::Sqlite
  property? failing : Bool = false

  def ping : Nil
    raise IO::Error.new("server closed the connection") if failing?
  end
end

private def establish_flaky(database : String, role : Symbol, replica_index : Int32 = 0, **options) : C02FailoverAdapter
  Grant::ConnectionRegistry.establish_connection(
    **options, database: database, adapter: C02FailoverAdapter, url: "sqlite3::memory:", role: role, replica_index: replica_index)
  Grant::ConnectionRegistry.connection_pool(database, role, replica_index: replica_index).not_nil!.adapter.as(C02FailoverAdapter)
end

private def establish_real(database : String, role : Symbol) : Grant::Adapter::Base
  Grant::ConnectionRegistry.establish_connection(
    database: database, adapter: C02Support.adapter_class, url: C02Support.url(database), role: role)
  Grant::ConnectionRegistry.get_adapter(database, role)
end

private def mark_down(database : String, role : Symbol, adapter : C02FailoverAdapter, replica_index : Int32 = 0) : Nil
  adapter.failing = true
  expect_raises(Grant::ConnectionFailed) { Grant::ConnectionRegistry.verify!(database, role, replica_index: replica_index) }
end

describe "connection failover" do
  after_each do
    Grant::ConnectionRegistry.clear_all
  end

  after_all { C02Support.cleanup }

  {:writing, :primary}.each do |writer_role|
    it "reads from the #{writer_role} connection when the only replica is unhealthy" do
      writer = establish_real("c02_failover", writer_role)
      replica = establish_flaky("c02_failover", :reading)

      Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(replica).should be_true

      mark_down("c02_failover", :reading, replica)
      Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(writer).should be_true

      replica.failing = false
      Grant::ConnectionRegistry.verify!("c02_failover", :reading)
      Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(replica).should be_true
    end
  end

  it "reads from the writer when no replica was ever registered" do
    writer = establish_real("c02_failover", :writing)

    Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(writer).should be_true
  end

  it "skips only the unhealthy replica when others are healthy" do
    writer = establish_real("c02_failover", :writing)
    bad = establish_flaky("c02_failover", :reading, replica_index: 0)
    good = establish_flaky("c02_failover", :reading, replica_index: 1)
    good.same?(bad).should be_false
    mark_down("c02_failover", :reading, bad, replica_index: 0)

    6.times { Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(good).should be_true }
    writer.should_not be_nil
  end

  it "falls back from an unhealthy writing connection to the primary one" do
    primary = establish_real("c02_failover", :primary)
    writer = establish_flaky("c02_failover", :writing)
    mark_down("c02_failover", :writing, writer)

    Grant::ConnectionRegistry.get_adapter("c02_failover", :writing).same?(primary).should be_true
  end

  it "returns the requested connection when nothing in the chain is healthy, so the caller sees the real error" do
    writer = establish_flaky("c02_failover", :writing)
    replica = establish_flaky("c02_failover", :reading)
    mark_down("c02_failover", :writing, writer)
    mark_down("c02_failover", :reading, replica)

    Grant::ConnectionRegistry.get_adapter("c02_failover", :reading).same?(replica).should be_true
    Grant::ConnectionRegistry.get_adapter("c02_failover", :writing).same?(writer).should be_true
  end

  it "still raises AdapterNotAvailableError when the connection was never established" do
    expect_raises(Grant::AdapterNotAvailableError) { Grant::ConnectionRegistry.get_adapter("c02_missing", :reading) }
  end

  it "drives connection settings from the model's failover_retry_attempts and health_check_interval" do
    writer = establish_real("c02_failover_model", :writing)

    C02FailoverModel.failover_retry_attempts = 7
    C02FailoverModel.health_check_interval = 90.seconds

    writer.retry_attempts.should eq 7
    spec = Grant::ConnectionRegistry.connection_spec("c02_failover_model", :writing).not_nil!
    spec.retry_attempts.should eq 7
    spec.health_check_interval.should eq 90.seconds

    # Connections established afterwards get the declared values too.
    later = establish_real("c02_failover_model", :reading)
    later.retry_attempts.should eq 7
    Grant::ConnectionRegistry.connection_spec("c02_failover_model", :reading).not_nil!.health_check_interval.should eq 90.seconds
  end
end

class C02FailoverModel < Grant::Base
  table c02_failover_models
  column id : Int64, primary: true
  connects_to database: {writing: "c02_failover_model", reading: "c02_failover_model"}
end
