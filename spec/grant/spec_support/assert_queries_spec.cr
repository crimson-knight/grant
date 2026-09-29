require "../../spec_helper"
require "../../../src/grant/spec_support/*"

describe Grant::Spec do
  before_each { Parent.clear }

  describe ".assert_queries_count" do
    it "passes for the exact count and returns the captured queries" do
      baseline = Grant::Spec.capture_queries { Parent.count }.size
      baseline.should be > 0

      queries = Grant::Spec.assert_queries_count(baseline) { Parent.count }
      queries.map(&.sql).all?(&.includes?("parents")).should be_true
    end

    it "fails with the captured SQL when the count differs" do
      error = expect_raises(::Spec::AssertionFailed) do
        Grant::Spec.assert_queries_count(0) { Parent.count }
      end

      message = error.message.to_s
      message.should contain("Expected 0 queries, but")
      message.should contain("Captured queries:")
      message.should contain("parents")
    end

    it "counts queries only for the fiber that runs the block" do
      baseline = Grant::Spec.capture_queries { Parent.count }.size
      finished = Channel(Nil).new

      Grant::Spec.assert_queries_count(baseline) do
        spawn do
          Parent.count
          Parent.count
          finished.send(nil)
        end
        finished.receive
        Parent.count
      end
    end

    it "attributes Async::Result queries to the fiber that started them" do
      baseline = Grant::Spec.capture_queries { Parent.count }.size

      Grant::Spec.assert_queries_count(baseline) { Parent.async_count.wait }
    end

    it "records nothing outside the block" do
      queries = Grant::Spec.capture_queries { Parent.count }
      Parent.count
      Grant::Notifications.subscribed?(Grant::Events::SQL).should be_false
      queries.size.should be > 0
    end
  end

  describe ".assert_no_queries" do
    it "passes when the block does not touch the database" do
      Grant::Spec.assert_no_queries { 1 + 1 }
    end

    it "fails and lists the statement that ran" do
      error = expect_raises(::Spec::AssertionFailed) do
        Grant::Spec.assert_no_queries { Parent.count }
      end

      error.message.to_s.should contain("Captured queries:")
    end

    it "says so when nothing was captured for a count that was expected" do
      error = expect_raises(::Spec::AssertionFailed) do
        Grant::Spec.assert_queries_count(1) { 1 + 1 }
      end

      error.message.to_s.should contain("No queries were captured.")
    end
  end

  describe ".assert_queries_match" do
    it "matches a regex or a substring" do
      Grant::Spec.assert_queries_match(/FROM\s+.?parents/i) { Parent.count }
      Grant::Spec.assert_queries_match("parents") { Parent.count }
    end

    it "checks the number of matching statements when count: is given" do
      Grant::Spec.assert_queries_match("parents", count: 1) { Parent.count }

      expect_raises(::Spec::AssertionFailed, "matching") do
        Grant::Spec.assert_queries_match("parents", count: 5) { Parent.count }
      end
    end

    it "fails and prints the statements when none match" do
      error = expect_raises(::Spec::AssertionFailed) do
        Grant::Spec.assert_queries_match(/users_table_nobody_has/) { Parent.count }
      end

      error.message.to_s.should contain("none matched")
      error.message.to_s.should contain("parents")
    end
  end

  describe ".assert_no_queries_match" do
    it "fails when a matching statement ran" do
      Grant::Spec.assert_no_queries_match("students") { Parent.count }

      expect_raises(::Spec::AssertionFailed) do
        Grant::Spec.assert_no_queries_match("parents") { Parent.count }
      end
    end
  end
end
