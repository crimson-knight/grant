require "../../spec_helper"
require "../sti/sti_behavior_models"

private def collect(event_type : T.class, & : ->) : Array(T) forall T
  events = [] of T
  handler = ->(event : T) { events << event; nil }
  Grant::Notifications.subscribed(event_type, handler) { yield }
  events
end

describe Grant::Notifications do
  before_each { Parent.clear }

  describe "SQL events" do
    it "carries the statement, binds, name, duration and connection" do
      Parent.create!(name: "notified")

      events = collect(Grant::Events::SQL) do
        Parent.where(name: "notified").select.size
      end

      event = events.find! { |candidate| candidate.sql.includes?("parents") && !candidate.binds.empty? }
      event.sql.should contain("FROM")
      event.binds.should eq(["notified"] of Grant::Columns::Type)
      event.name.should eq("Parent")
      event.duration.should be >= Time::Span.zero
      event.connection.should eq(Parent.adapter.name)
      event.cached?.should be_false
      event.async?.should be_false
    end

    it "reports writes issued through the adapter" do
      events = collect(Grant::Events::SQL) { Parent.create!(name: "written") }

      insert = events.find! { |candidate| candidate.sql.starts_with?("INSERT") }
      insert.sql.should contain("parents")
      insert.binds.should contain("written")
    end

    it "marks statements run on an Async::Result fiber" do
      Parent.create!(name: "async")

      events = collect(Grant::Events::SQL) do
        Parent.async_count.wait
      end

      events.select(&.sql.includes?("parents")).should_not be_empty
      events.select(&.sql.includes?("parents")).all?(&.async?).should be_true
    end

    it "reports aggregate and typed pluck statements with their binds and model" do
      Parent.create!(name: "summed")

      events = collect(Grant::Events::SQL) do
        Parent.where(name: "summed").sum(:id)
        Parent.where(name: "summed").pluck_as(name: String)
      end

      aggregate = events.find! { |candidate| candidate.sql.includes?("SUM(") }
      aggregate.binds.should eq(["summed"] of Grant::Columns::Type)
      aggregate.name.should eq("Parent")
      plucked = events.find! { |candidate| candidate.sql.includes?("parents") && !candidate.sql.includes?("SUM(") }
      plucked.binds.should eq(["summed"] of Grant::Columns::Type)
      plucked.name.should eq("Parent")
    end

    it "publishes a statement that fails" do
      events = collect(Grant::Events::SQL) do
        expect_raises(Exception) { Parent.query("SELECT * FROM missing_table_for_notifications") { } }
      end

      events.map(&.sql).should contain("SELECT * FROM missing_table_for_notifications")
    end

    it "stops delivering after unsubscribe and builds nothing without a subscriber" do
      received = 0
      subscription = Grant::Notifications.subscribe(Grant::Events::SQL) { |_| received += 1 }
      Parent.count
      subscription.unsubscribe
      after = received
      Parent.count

      after.should be > 0
      received.should eq(after)
      Grant::Notifications.subscribed?(Grant::Events::SQL).should be_false

      built = false
      Grant::Notifications.instrument(Grant::Events::SQL) do
        built = true
        Grant::Events::SQL.new("SELECT 1", [] of Grant::Columns::Type, "SQL", Time::Span.zero, "x")
      end
      built.should be_false
    end

    it "does not let a failing subscriber break the statement it observes" do
      subscription = Grant::Notifications.subscribe(Grant::Events::SQL) { |_| raise "subscriber failure" }
      begin
        Parent.create!(name: "survives")
        Parent.count.should eq(1)
      ensure
        subscription.unsubscribe
      end
    end
  end

  describe "instantiation events" do
    it "publishes one event per record built from a row" do
      Parent.create!(name: "a")
      Parent.create!(name: "b")

      events = collect(Grant::Events::Instantiation) { Parent.all.to_a }

      events.size.should eq(2)
      events.map(&.class_name).uniq!.should eq(["Parent"])
      events.sum(&.record_count).should eq(2)
    end

    it "publishes STI records under their final class, from root and subclass queries" do
      setup_behavior_sti_tables
      BehaviorPersona.create!(name: "plain")
      BehaviorAdminPersona.create!(name: "admin")

      from_root = collect(Grant::Events::Instantiation) { BehaviorPersona.all.to_a }
      from_root.map(&.class_name).sort.should eq(["BehaviorAdminPersona", "BehaviorPersona"])

      from_subclass = collect(Grant::Events::Instantiation) { BehaviorAdminPersona.all.to_a }
      from_subclass.map(&.class_name).should eq(["BehaviorAdminPersona"])
    end
  end

  describe "strict loading violation events" do
    it "publishes the owner and association before raising" do
      parent = Parent.create!(name: "strict")
      parent.strict_loading!

      events = collect(Grant::Events::StrictLoadingViolation) do
        expect_raises(Grant::StrictLoadingViolationError) { parent.students.to_a }
      end

      events.size.should eq(1)
      events.first.owner.should eq("Parent")
      events.first.association.should eq("students")
    end
  end
end
