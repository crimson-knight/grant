require "../../spec_helper"

# Counts the statements crystal-db executes while a block runs.
class W6PerfStatementLog < Log::Backend
  getter list_of_statements = [] of String

  def initialize
    super(:direct)
  end

  def write(entry : Log::Entry) : Nil
    return unless entry.message == "Executing query"
    @list_of_statements << entry.data[:query].to_s
  end
end

W6_PERF_STATEMENT_LOG = W6PerfStatementLog.new

# The statement that opens a transaction: MySQL sends START TRANSACTION.
W6_PERF_BEGIN = CURRENT_ADAPTER == "mysql" ? "START TRANSACTION" : "BEGIN"

private def w6_perf_statements(& : ->) : Array(String)
  W6_PERF_STATEMENT_LOG.list_of_statements.clear
  Log.builder.bind("db", Log::Severity::Debug, W6_PERF_STATEMENT_LOG)
  begin
    yield
  ensure
    Log.builder.unbind("db", Log::Severity::Debug, W6_PERF_STATEMENT_LOG)
  end
  W6_PERF_STATEMENT_LOG.list_of_statements.dup
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6PerfPerson < Grant::Base
    connection {{ adapter_literal }}
    table w6_perf_people

    column id : Int64, primary: true
    column name : String
    column score : Int32?
    timestamps
  end

  # A before_save callback that writes another row, so the save's transaction
  # has a statement to carry even though the record itself is clean.
  class W6PerfAuditedPerson < Grant::Base
    connection {{ adapter_literal }}
    table w6_perf_audited_people

    column id : Int64, primary: true
    column name : String
    column touches : Int32 = 0

    before_save :write_audit_row

    private def write_audit_row
      W6PerfPerson.create!(name: "audit of #{name}")
    end
  end
{% end %}

W6PerfPerson.migrator.drop_and_create
W6PerfAuditedPerson.migrator.drop_and_create

describe "Statement counts of the persistence paths" do
  before_each do
    W6PerfPerson.clear
    W6PerfAuditedPerson.clear
  end

  describe "create" do
    it "runs BEGIN, INSERT and COMMIT and nothing else" do
      person = nil
      statements = w6_perf_statements do
        person = W6PerfPerson.create!(name: "Ada", score: 3)
      end

      statements.size.should eq(3)
      statements[0].should start_with(W6_PERF_BEGIN)
      statements[1].should start_with("INSERT INTO")
      statements[2].should eq("COMMIT")
      person.not_nil!.id.should_not be_nil
      W6PerfPerson.find!(person.not_nil!.id).name.should eq("Ada")
    end

    it "reports the generated id without a second query" do
      first = W6PerfPerson.create!(name: "one")
      second = W6PerfPerson.create!(name: "two")

      second.id.not_nil!.should be > first.id.not_nil!
      W6PerfPerson.find!(second.id).name.should eq("two")
    end

    it "runs one INSERT for a build-then-save as well" do
      person = W6PerfPerson.new(name: "built")
      statements = w6_perf_statements { person.save.should be_true }

      statements.map(&.split(' ').first).should eq([W6_PERF_BEGIN.split(' ').first, "INSERT", "COMMIT"])
    end
  end

  describe "find" do
    it "runs one SELECT" do
      person = W6PerfPerson.create!(name: "Grace")

      found = nil
      statements = w6_perf_statements { found = W6PerfPerson.find(person.id) }

      statements.size.should eq(1)
      statements[0].should start_with("SELECT")
      found.not_nil!.name.should eq("Grace")
    end

    it "find! runs one SELECT and find returns nil for a missing key" do
      person = W6PerfPerson.create!(name: "Hopper")

      statements = w6_perf_statements { W6PerfPerson.find!(person.id).name.should eq("Hopper") }
      statements.size.should eq(1)

      W6PerfPerson.find(-1_i64).should be_nil
      expect_raises(Grant::Querying::NotFound) { W6PerfPerson.find!(-1_i64) }
    end

    it "builds the same statement as the relation it replaces" do
      person = W6PerfPerson.create!(name: "Lovelace")

      kept = w6_perf_statements { W6PerfPerson.find(person.id) }
      relation = w6_perf_statements { W6PerfPerson.where(:id, :eq, person.id).first }

      kept.should eq(relation)
    end
  end

  describe "save" do
    it "runs nothing for a record with no changes" do
      person = W6PerfPerson.create!(name: "Clean")
      loaded = W6PerfPerson.find!(person.id)

      statements = w6_perf_statements { loaded.save.should be_true }

      statements.should be_empty
    end

    it "runs nothing for a record that was just saved" do
      person = W6PerfPerson.create!(name: "Fresh")

      statements = w6_perf_statements { person.save.should be_true }

      statements.should be_empty
    end

    it "runs BEGIN, UPDATE and COMMIT for a change" do
      loaded = W6PerfPerson.find!(W6PerfPerson.create!(name: "Before").id)
      loaded.name = "After"

      statements = w6_perf_statements { loaded.save.should be_true }

      statements.size.should eq(3)
      statements[0].should start_with(W6_PERF_BEGIN)
      statements[1].should start_with("UPDATE")
      statements[2].should eq("COMMIT")
      W6PerfPerson.find!(loaded.id).name.should eq("After")
    end

    it "sends BEGIN when a callback of a clean record writes" do
      audited = W6PerfAuditedPerson.create!(name: "audited")
      W6PerfPerson.clear
      loaded = W6PerfAuditedPerson.find!(audited.id)

      statements = w6_perf_statements { loaded.save.should be_true }

      statements.first.should start_with(W6_PERF_BEGIN)
      statements.last.should eq("COMMIT")
      statements.count(&.starts_with?("INSERT INTO")).should eq(1)
      W6PerfPerson.count.should eq(1)
    end

    it "rolls the callback's write back when the transaction does" do
      audited = W6PerfAuditedPerson.create!(name: "audited")
      W6PerfPerson.clear
      loaded = W6PerfAuditedPerson.find!(audited.id)

      W6PerfAuditedPerson.transaction do
        loaded.save.should be_true
        raise Grant::Transaction::Rollback.new
      end

      W6PerfPerson.count.should eq(0)
    end

    it "still restores a record's state when its transaction rolls back" do
      person = W6PerfPerson.create!(name: "Original")
      loaded = W6PerfPerson.find!(person.id)

      W6PerfPerson.transaction do
        loaded.name = "Changed"
        loaded.save!
        raise Grant::Transaction::Rollback.new
      end

      W6PerfPerson.find!(person.id).name.should eq("Original")
    end
  end

  describe "explicit transactions" do
    it "still send BEGIN and COMMIT, and run after_commit work" do
      committed = false
      statements = w6_perf_statements do
        W6PerfPerson.transaction do
          W6PerfPerson.current_transaction.after_commit { committed = true }
        end
      end

      committed.should be_true
      statements.size.should eq(2)
      statements[0].should start_with(W6_PERF_BEGIN)
      statements[1].should eq("COMMIT")
    end

    it "send one BEGIN and one COMMIT around several saves" do
      statements = w6_perf_statements do
        W6PerfPerson.transaction do
          W6PerfPerson.create!(name: "a")
          W6PerfPerson.create!(name: "b")
        end
      end

      statements.count(&.starts_with?(W6_PERF_BEGIN)).should eq(1)
      statements.count(&.==("COMMIT")).should eq(1)
      statements.count(&.starts_with?("INSERT INTO")).should eq(2)
    end
  end
end
