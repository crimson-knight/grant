require "../../spec_helper"
require "../../support/w6_c04_support"

# The table has no `ghost` column, but W6SqlGhostThing declares one, so any
# statement that names it fails in the database. W6SqlThing reaches the same
# table with only real columns; its failures come from a raw `missing_col`.
class W6SqlThing < Grant::Base
  connection "w6_sql"
  table w6_sql_things
  column id : Int64, primary: true
  column label : String?
  column amount : Int64?
end

class W6SqlGhostThing < Grant::Base
  connection "w6_sql"
  table w6_sql_things
  column id : Int64, primary: true
  column label : String?
  column ghost : String?
end

# Runs the block, which must fail in the database, and returns the error after
# checking it carries the statement.
private def w6_failure(fragment : String, &) : Grant::StatementInvalid
  error = expect_raises(Grant::StatementInvalid) { yield }
  error.sql.should_not be_nil
  error.sql.to_s.should contain fragment
  error.cause.should_not be_nil
  error
end

# As `w6_failure`, for a write that the model wraps in Grant::RecordNotSaved:
# the wrapped StatementInvalid is the cause.
private def w6_wrapped_failure(fragment : String, &) : Grant::StatementInvalid
  error = expect_raises(Grant::RecordNotSaved) { yield }
  cause = error.cause
  cause.should be_a(Grant::StatementInvalid)
  statement = cause.as(Grant::StatementInvalid)
  statement.sql.to_s.should contain fragment
  statement
end

describe "StatementInvalid carries the statement on every path (#{CURRENT_ADAPTER})" do
  before_all do
    W6C04.provision("w6_sql", ["CREATE TABLE w6_sql_things (#{W6C04.id_column}, label TEXT, amount BIGINT)"])
    W6C04.establish("w6_sql", "w6_sql", :primary)
    W6C04.exec("w6_sql", "INSERT INTO w6_sql_things (label, amount) VALUES ('a', 1)")
  end

  after_all do
    W6C04.remove("w6_sql", :primary)
    W6C04.cleanup
  end

  describe "the query builder" do
    it "reports the statement of select, first, last and find_by" do
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").select }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").first }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").last }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").find_by(label: "a") }
    end

    it "reports the statement of count, exists?, pluck, pick and ids" do
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").count }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").exists? }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").pluck(:label) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").pluck(:label, :amount) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").pick(:label) }
    end

    it "reports the statement of the aggregations" do
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").sum(:amount) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").avg(:amount) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").min(:amount) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").max(:amount) }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").group(:label).count }
    end

    it "reports the statement of update_all, delete_all and find_each" do
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").update_all(label: "x") }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").delete_all }
      w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").find_each { |_| } }
    end
  end

  describe "model reads, writes and raw SQL" do
    it "reports the statement of a select naming a column the table lacks" do
      w6_failure("ghost") { W6SqlGhostThing.first }
      w6_failure("ghost") { W6SqlGhostThing.all.to_a }
      w6_failure("ghost") { W6SqlGhostThing.find(1) }
    end

    it "reports the statement of an insert, an update and a delete" do
      w6_wrapped_failure("INSERT") { W6SqlGhostThing.new(label: "x", ghost: "y").save! }
      w6_wrapped_failure("ghost") { W6SqlGhostThing.create!(label: "x", ghost: "y") }
      w6_failure("ghost") { W6SqlGhostThing.where(label: "a").update_all(ghost: "z") }
    end

    it "reports the statement of the raw SQL entry points of a model" do
      w6_failure("missing_col") { W6SqlThing.all("WHERE missing_col = ?", [1_i64]).to_a }
      w6_failure("missing_col") { W6SqlThing.first("WHERE missing_col = ?", [1_i64]) }
      w6_failure("missing_col") { W6SqlThing.find_by_sql("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { W6SqlThing.connection.select_all("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { W6SqlThing.connection.execute("UPDATE w6_sql_things SET missing_col = 1") }
    end

    it "reports the statement of the connection facade" do
      w6_failure("missing_col") { Grant.connection("w6_sql").select_all("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { Grant.connection("w6_sql").select_value("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { Grant.connection("w6_sql").select_rows("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { Grant.connection("w6_sql").exec_query("SELECT missing_col FROM w6_sql_things") }
      w6_failure("missing_col") { Grant.connection("w6_sql").with_result_set("SELECT missing_col FROM w6_sql_things") { |_| } }
    end
  end

  describe "a helper that opens the adapter without SQL" do
    sql = "SELECT missing_col FROM w6_sql_things"

    it "still names the statement that failed" do
      adapter = Grant::ConnectionRegistry.get_adapter("w6_sql", :primary)

      w6_failure("missing_col") { adapter.open(&.scalar(sql)) }
    end

    it "names it inside a transaction, a pinned connection and a rolled back block" do
      adapter = Grant::ConnectionRegistry.get_adapter("w6_sql", :primary)

      w6_failure("missing_col") { W6SqlThing.transaction { adapter.open(&.scalar(sql)) } }
      w6_failure("missing_col") { adapter.with_connection { |_| adapter.open(&.scalar(sql)) } }
    end

    it "names the statement of the last failing call, not an earlier one" do
      adapter = Grant::ConnectionRegistry.get_adapter("w6_sql", :primary)
      adapter.open(&.scalar("SELECT 1"))

      error = w6_failure("w6_sql_things") { adapter.open { |db| db.exec("UPDATE w6_sql_things SET missing_col = 1") } }
      error.sql.to_s.should contain "UPDATE"
    end

    it "keeps an explicit statement over the last one built" do
      adapter = Grant::ConnectionRegistry.get_adapter("w6_sql", :primary)

      error = w6_failure("explicit label") { adapter.open("explicit label", &.scalar(sql)) }
      error.sql.should eq "explicit label"
    end
  end

  describe "binds" do
    it "redacts bound values unless capturing is enabled, and bounds them when it is" do
      error = w6_failure("missing_col") { W6SqlThing.where("missing_col = ?", "secret-value").select }
      error.binds.should eq ["[FILTERED]"]
      error.to_s.should_not contain "secret-value"

      Grant.settings.capture_statement_bind_values = true
      begin
        long = "x" * 500
        captured = w6_failure("missing_col") { W6SqlThing.where("missing_col = ?", long).select }
        captured.binds.size.should eq 1
        captured.binds.first.size.should be <= Grant::StatementInvalid::MAX_BIND_LENGTH + 3
      ensure
        Grant.settings.capture_statement_bind_values = false
      end
    end

    it "keeps no more binds than the cap" do
      values = (1..60).map { |n| n.to_i64.as(Grant::Columns::Type) }
      error = w6_failure("missing_col") { W6SqlThing.where("missing_col IN (#{values.map { "?" }.join(", ")})", values).select }
      error.binds.size.should be <= Grant::StatementInvalid::MAX_BINDS
    end
  end

  it "is a Grant::ErrorBase carrying the driver's error as its cause" do
    error = w6_failure("missing_col") { W6SqlThing.where("missing_col = 1").select }
    error.should be_a(Grant::ErrorBase)
    error.message.to_s.should_not be_empty
  end
end
