require "./pool_spec_support"

class C02PinnedItem < Grant::Base
  table c02_pinned_items
  column id : Int64, primary: true
  column name : String?
  connects_to database: "c02_pin"
end

describe "with_connection" do
  before_each do
    C02Support.establish("c02_pin", pool_size: 3, initial_pool_size: 1, max_idle_pool_size: 3)
    C02Support.adapter_class # touch
    Grant::ConnectionRegistry.get_adapter("c02_pin", :writing).open do |connection|
      connection.exec "DROP TABLE IF EXISTS c02_pinned_items"
      connection.exec CURRENT_ADAPTER == "pg" ? "CREATE TABLE c02_pinned_items (id BIGSERIAL PRIMARY KEY, name TEXT)" : "CREATE TABLE c02_pinned_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)"
    end
  end

  after_each do
    Grant::ConnectionRegistry.get_adapter("c02_pin", :writing).open { |connection| connection.exec "DROP TABLE IF EXISTS c02_pinned_items" }
    Grant::ConnectionRegistry.remove_connection("c02_pin", :writing)
  end

  after_all { C02Support.cleanup }

  it "keeps every statement of the block on one connection, so session state survives" do
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)

    adapter.with_connection do |raw|
      raw.exec "CREATE TEMP TABLE c02_scratch (id INTEGER)"
      # Without the pin these would check out other connections, which cannot see the temp table.
      adapter.open { |connection| connection.exec "INSERT INTO c02_scratch VALUES (1)" }
      adapter.open { |connection| connection.exec "INSERT INTO c02_scratch VALUES (2)" }
      adapter.open { |connection| connection.scalar("SELECT COUNT(*) FROM c02_scratch") }.should eq 2
      adapter.open { |connection| connection.same?(raw) }.should be_true
      adapter.pool_stat.busy.should eq 1
    end
  end

  it "releases the connection when the block ends, and when it raises" do
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)

    adapter.with_connection { |raw| raw.scalar("SELECT 1") }
    adapter.pool_stat.busy.should eq 0
    adapter.pinned_connection?.should be_nil

    expect_raises(Exception, "boom") { adapter.with_connection { |_| raise "boom" } }
    adapter.pool_stat.busy.should eq 0
    adapter.pinned_connection?.should be_nil
  end

  it "reuses the pinned connection when nested" do
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)

    adapter.with_connection do |outer|
      adapter.with_connection { |inner| inner.same?(outer).should be_true }
      adapter.pool_stat.busy.should eq 1
    end
  end

  it "pins only the calling fiber" do
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)
    other_fiber_saw_pin = Channel(Bool).new

    adapter.with_connection do |raw|
      spawn { adapter.open { |connection| other_fiber_saw_pin.send(connection.same?(raw)) } }
      other_fiber_saw_pin.receive.should be_false
    end
  end

  it "runs a transaction opened inside the block on the pinned connection" do
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)

    adapter.with_connection do |raw|
      seen = nil
      C02PinnedItem.transaction do
        C02PinnedItem.create!(name: "kept")
        seen = C02PinnedItem.adapter.open { |connection| connection.same?(raw) }
      end
      seen.should be_true

      expect_raises(Exception, "rolled back") do
        C02PinnedItem.transaction do
          C02PinnedItem.create!(name: "discarded")
          raise "rolled back"
        end
      end
      adapter.pinned_connection?.should_not be_nil
    end

    C02PinnedItem.all.map(&.name).should eq ["kept"]
  end

  it "routes Grant operations through the pinned connection with Model.with_connection" do
    C02PinnedItem.with_connection do |raw|
      raw.exec "CREATE TEMP TABLE c02_model_scratch (id INTEGER)"
      C02PinnedItem.connection.execute("INSERT INTO c02_model_scratch VALUES (1)")
      C02PinnedItem.connection.execute("INSERT INTO c02_model_scratch VALUES (2)")
      C02PinnedItem.connection.select_value("SELECT COUNT(*) FROM c02_model_scratch").should eq 2
      C02PinnedItem.create!(name: "inside").id.should_not be_nil
    end

    C02PinnedItem.count.should eq 1
    C02PinnedItem.adapter.pool_stat.busy.should eq 0
  end

  it "is available on the raw connection facade and the pool handle" do
    Grant.connection("c02_pin").with_connection do |raw|
      raw.exec "CREATE TEMP TABLE c02_facade_scratch (id INTEGER)"
      Grant.connection("c02_pin").execute("INSERT INTO c02_facade_scratch VALUES (1)")
      Grant.connection("c02_pin").select_value("SELECT COUNT(*) FROM c02_facade_scratch").should eq 1
    end

    C02PinnedItem.connection_pool.with_connection { |raw| raw.scalar("SELECT 1") }.should eq 1
  end

  it "keeps a second fiber waiting on the checkout timeout while the pool is exhausted by pins" do
    Grant::ConnectionRegistry.establish_connection(
      database: "c02_pin", adapter: C02Support.adapter_class, url: C02Support.url("c02_pin"),
      role: :writing, pool_size: 1, initial_pool_size: 1, checkout_timeout: 100.milliseconds)
    adapter = Grant::ConnectionRegistry.get_adapter("c02_pin", :writing)
    blocked = Channel(Exception?).new

    adapter.with_connection do |_|
      spawn do
        begin
          adapter.open { |connection| connection.scalar("SELECT 1") }
          blocked.send(nil)
        rescue ex
          blocked.send(ex)
        end
      end
      blocked.receive.should be_a(Grant::ConnectionTimeoutError)
    end
  end
end

describe "configured role names" do
  after_each do
    Grant.settings.reading_role = :reading
    Grant.settings.writing_role = :writing
    Grant::ConnectionRegistry.remove_connection("c02_roles", :writing)
    Grant::ConnectionRegistry.remove_connection("c02_roles", :reading)
  end

  after_all { C02Support.cleanup }

  it "resolves the raw connection facade and model transactions through Grant.settings roles" do
    Grant.settings.reading_role = :replica
    Grant.settings.writing_role = :master
    writer = C02Support.establish("c02_roles", :writing)
    reader = C02Support.establish("c02_roles", :reading)

    connection = Grant.connection("c02_roles")
    connection.adapter(:master).same?(writer).should be_true
    connection.adapter(:replica).same?(reader).should be_true
    connection.adapter.same?(reader).should be_true
    connection.execute("SELECT 1")
    connection.select_value("SELECT 1").should eq 1

    connection.transaction { connection.select_value("SELECT 1") }.should eq 1
    handle = connection.begin_transaction
    handle.rollback

    C02RoleModel.transaction_adapter.same?(writer).should be_true
  end
end

class C02RoleModel < Grant::Base
  table c02_role_models
  column id : Int64, primary: true
  connects_to database: {master: "c02_roles", replica: "c02_roles"}
end
