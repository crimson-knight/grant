require "../spec_helper"

class ConnectionDatabaseContextTestModel < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table connection_database_context_test_models

  column id : Int64, primary: true
end

describe "Grant::ConnectionManagement database context" do
  it "restores the default database after overlapping fiber contexts" do
    original_database = ConnectionDatabaseContextTestModel.database_name
    fiber_a_entered = Channel(Nil).new
    fiber_b_entered = Channel(Nil).new
    fiber_a_exited = Channel(Nil).new
    fiber_b_exited = Channel(Nil).new

    database_seen_by_a = ""
    database_seen_by_a_after_b_entered = ""
    database_seen_by_b = ""
    database_seen_by_b_after_a_exited = ""
    default_database_seen_by_b_after_a_exited = ""

    spawn do
      ConnectionDatabaseContextTestModel.connected_to(database: "context_database_a") do
        database_seen_by_a = ConnectionDatabaseContextTestModel.current_database
        fiber_a_entered.send(nil)
        fiber_b_entered.receive
        database_seen_by_a_after_b_entered = ConnectionDatabaseContextTestModel.current_database
      end
      fiber_a_exited.send(nil)
    end

    spawn do
      fiber_a_entered.receive
      ConnectionDatabaseContextTestModel.connected_to(database: "context_database_b") do
        database_seen_by_b = ConnectionDatabaseContextTestModel.current_database
        fiber_b_entered.send(nil)
        fiber_a_exited.receive
        database_seen_by_b_after_a_exited = ConnectionDatabaseContextTestModel.current_database
        default_database_seen_by_b_after_a_exited = ConnectionDatabaseContextTestModel.default_database_name
      end
      fiber_b_exited.send(nil)
    end

    fiber_b_exited.receive

    database_seen_by_a.should eq("context_database_a")
    database_seen_by_a_after_b_entered.should eq("context_database_a")
    database_seen_by_b.should eq("context_database_b")
    database_seen_by_b_after_a_exited.should eq("context_database_b")
    default_database_seen_by_b_after_a_exited.should eq(original_database)
    ConnectionDatabaseContextTestModel.database_name.should eq(original_database)
    ConnectionDatabaseContextTestModel.current_database.should eq(original_database)
  end
end
