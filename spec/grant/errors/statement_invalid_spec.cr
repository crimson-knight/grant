require "../../spec_helper"

private def with_bind_capture(enabled : Bool, &)
  previous = Grant.settings.capture_statement_bind_values?
  Grant.settings.capture_statement_bind_values = enabled
  begin
    yield
  ensure
    Grant.settings.capture_statement_bind_values = previous
  end
end

describe Grant::StatementInvalid do
  describe "carried statement" do
    it "keeps the sql and one redacted entry per bind by default" do
      error = Grant::StatementInvalid.new("boom", "SELECT * FROM users WHERE ssn = ? AND id = ?", ["123-45-6789", 7])

      error.message.should eq("boom")
      error.sql.should eq("SELECT * FROM users WHERE ssn = ? AND id = ?")
      error.binds.should eq(["[FILTERED]", "[FILTERED]"])
      error.binds.join.should_not contain("123-45-6789")
    end

    it "defaults to no sql and no binds" do
      error = Grant::StatementInvalid.new("boom")
      error.sql.should be_nil
      error.binds.should be_empty
    end

    it "keeps the driver error as the cause" do
      driver_error = DB::Error.new("driver")
      Grant::StatementInvalid.new("boom", cause: driver_error).cause.should be(driver_error)
    end

    it "keeps truncated bind values when capture is enabled" do
      with_bind_capture(true) do
        error = Grant::StatementInvalid.new("boom", "SELECT ?", ["short", 42, nil])
        error.binds.should eq(["short", "42", ""])
      end
    end
  end

  describe "bounds on retained binds" do
    it "truncates each captured value" do
      with_bind_capture(true) do
        error = Grant::StatementInvalid.new("boom", "SELECT ?", ["x" * 1_000_000])
        error.binds.first.size.should eq(Grant::StatementInvalid::MAX_BIND_LENGTH + 3)
        error.binds.first.should end_with("...")
      end
    end

    it "caps how many binds are kept" do
      binds = Array.new(500) { |i| i }
      Grant::StatementInvalid.new("boom", "SELECT 1", binds).binds.size.should eq(Grant::StatementInvalid::MAX_BINDS)
      with_bind_capture(true) do
        Grant::StatementInvalid.new("boom", "SELECT 1", binds).binds.size.should eq(Grant::StatementInvalid::MAX_BINDS)
      end
    end

    it "never retains the original values" do
      payload = "x" * 1_000_000
      error = Grant::StatementInvalid.new("boom", "SELECT ?", [payload])
      error.binds.first.should eq("[FILTERED]")
    end
  end

  describe "raised by an adapter" do
    it "reports the failing sql and redacted binds" do
      adapter = Parent.adapter
      secret = "sekrit-value"

      error = expect_raises(Grant::StatementInvalid) do
        adapter.exists?("g01_missing_table", "name = ?", [secret] of Grant::Columns::Type)
      end

      error.sql.to_s.should contain("g01_missing_table")
      error.sql.to_s.should start_with("SELECT EXISTS(")
      error.binds.should eq(["[FILTERED]"])
      error.message.to_s.should_not contain(secret) if adapter.postgres?
      error.cause.should_not be_nil
    end

    it "reports the failing sql from a write" do
      adapter = Parent.adapter

      error = expect_raises(Grant::StatementInvalid) do
        adapter.insert("g01_missing_table", ["name"], ["value"] of Grant::Columns::Type, lastval: nil)
      end

      error.sql.to_s.should contain("INSERT INTO")
      error.sql.to_s.should contain("g01_missing_table")
      error.binds.size.should eq(1)
    end

    it "includes captured values only when capture is enabled" do
      adapter = Parent.adapter

      with_bind_capture(true) do
        error = expect_raises(Grant::StatementInvalid) do
          adapter.exists?("g01_missing_table", "name = ?", ["visible"] of Grant::Columns::Type)
        end
        error.binds.should eq(["visible"])
      end
    end

    it "reports the statement that failed when the caller did not pass one" do
      error = expect_raises(Grant::StatementInvalid) do
        Parent.adapter.open { |db| db.exec "SELECT * FROM g01_missing_table" }
      end
      error.sql.should eq "SELECT * FROM g01_missing_table"
    end

    it "prefers the statement the caller passed" do
      error = expect_raises(Grant::StatementInvalid) do
        Parent.adapter.open("labelled statement") { |db| db.exec "SELECT * FROM g01_missing_table" }
      end
      error.sql.should eq "labelled statement"
    end
  end
end
