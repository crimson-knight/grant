require "../../spec_helper"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class LockClauseSpecItem < Grant::Base
  connection {{adapter_literal}}
  table lock_clause_spec_items

  column id : Int64, primary: true
  column label : String
end
{% end %}

LockClauseSpecItem.migrator.drop_and_create

LOCK_CLAUSE_SPEC_NO_KEY = Grant::Locking.clause("FOR NO KEY UPDATE")
LOCK_CLAUSE_SPEC_OF     = Grant::Locking.clause("FOR UPDATE OF lock_clause_spec_items")

private def lock_clause_spec_pg
  Grant::Adapter::Pg.new("lock_clause_pg", "postgres://localhost/lock_clause")
end

private def lock_clause_spec_sqlite
  Grant::Adapter::Sqlite.new("lock_clause_sqlite", "sqlite3::memory:")
end

describe "Relation#lock with a clause or false" do
  before_each { LockClauseSpecItem.clear }

  describe "Grant::Locking.clause" do
    it "accepts a string literal and a constant" do
      Grant::Locking.clause("FOR SHARE").sql.should eq("FOR SHARE")
      LOCK_CLAUSE_SPEC_NO_KEY.sql.should eq("FOR NO KEY UPDATE")
      LOCK_CLAUSE_SPEC_NO_KEY.to_s.should eq("FOR NO KEY UPDATE")
    end

    it "rejects a clause that is not plain keywords and identifiers, even from a constant" do
      injected = "FOR UPDATE; DROP TABLE lock_clause_spec_items"
      expect_raises(ArgumentError, "Invalid lock clause") do
        Grant::Locking::Clause.__from_literal(injected)
      end
      expect_raises(ArgumentError) { Grant::Locking::Clause.__from_literal("FOR UPDATE -- x") }
      expect_raises(ArgumentError) { Grant::Locking::Clause.__from_literal("") }
      expect_raises(ArgumentError) { Grant::Locking::Clause.__from_literal("FOR UPDATE 'x'") }
    end

    it "does not compile for a value built at runtime" do
      compiler = Process.find_executable("crystal-alpha")
      pending!("crystal-alpha is not on PATH") unless compiler

      root = File.expand_path("../../..", __DIR__)
      source = File.tempfile("lock_clause_runtime", ".cr", dir: root) do |file|
        file.puts %(require "./src/grant")
        file.puts %(name = ARGV[0]? || "x")
        file.puts %(Grant::Locking.clause("FOR \#{name}"))
      end

      begin
        output = IO::Memory.new
        status = Process.run(compiler.not_nil!, ["build", "--no-codegen", source.path], output: output, error: output, chdir: root)
        status.success?.should be_false
        output.to_s.should contain("takes a string literal or a constant")
      ensure
        source.delete
      end
    end
  end

  describe "the SQL" do
    it "appends the clause on PostgreSQL" do
      pg = lock_clause_spec_pg
      relation = LockClauseSpecItem.where(id: 1).lock(LOCK_CLAUSE_SPEC_NO_KEY)

      relation.lock_sql(pg).should eq("FOR NO KEY UPDATE")
      relation.lock_clause.should eq(LOCK_CLAUSE_SPEC_NO_KEY)
      relation.lock_mode.should be_nil
      LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_OF).lock_sql(pg).should eq("FOR UPDATE OF lock_clause_spec_items")
    end

    it "is a no-op on SQLite, which has no row locks" do
      LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).lock_sql(lock_clause_spec_sqlite).should eq("")
    end

    it "ends up in the generated select for the running adapter" do
      sql = LockClauseSpecItem.where(id: 1).lock(LOCK_CLAUSE_SPEC_NO_KEY).to_sql
      if LockClauseSpecItem.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update)
        sql.should end_with("FOR NO KEY UPDATE")
      else
        sql.should_not contain("FOR ")
      end
    end

    it "runs on the database (rows come back either way)" do
      item = LockClauseSpecItem.create!(label: "a")
      LockClauseSpecItem.transaction do
        LockClauseSpecItem.where(id: item.id).lock(LOCK_CLAUSE_SPEC_NO_KEY).first!.label.should eq("a")
      end
    end
  end

  describe "replacing a lock" do
    it "lets a clause replace a mode and a mode replace a clause" do
      by_mode = LockClauseSpecItem.lock(Grant::Locking::LockMode::Share)
      by_clause = by_mode.lock(LOCK_CLAUSE_SPEC_NO_KEY)
      by_clause.lock_mode.should be_nil
      by_clause.lock_clause.should_not be_nil

      back = by_clause.lock(Grant::Locking::LockMode::UpdateNoWait)
      back.lock_clause.should be_nil
      back.lock_mode.should eq(Grant::Locking::LockMode::UpdateNoWait)
    end

    it "never changes the relation it was called on" do
      original = LockClauseSpecItem.lock
      original.lock(LOCK_CLAUSE_SPEC_NO_KEY)
      original.unlock

      original.lock_mode.should eq(Grant::Locking::LockMode::Update)
      original.lock_clause.should be_nil
    end
  end

  describe "unlock" do
    it "drops a mode lock" do
      relation = LockClauseSpecItem.where(id: 1).lock
      relation.unlock.lock_mode.should be_nil
      relation.unlock.lock_sql(lock_clause_spec_pg).should be_nil
      relation.unlock.to_sql.should_not contain("FOR ")
    end

    it "drops a clause lock" do
      relation = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).unlock
      relation.lock_clause.should be_nil
      relation.lock_sql(lock_clause_spec_pg).should be_nil
    end

    it "is what lock(false) does, and lock(true) is plain lock" do
      LockClauseSpecItem.lock.lock(false).lock_mode.should be_nil
      LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).lock(false).lock_clause.should be_nil
      LockClauseSpecItem.lock(true).lock_mode.should eq(Grant::Locking::LockMode::Update)
      LockClauseSpecItem.lock(Grant::Locking::LockMode::Share).lock(true).lock_mode.should eq(Grant::Locking::LockMode::Update)
    end

    it "clears a lock inherited from a named scope or a merge" do
      locked = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY)
      merged = LockClauseSpecItem.where(id: 1).merge(locked)
      merged.lock_clause.should eq(LOCK_CLAUSE_SPEC_NO_KEY)
      merged.unlock.lock_clause.should be_nil
      merged.unscope(:lock).lock_clause.should be_nil
    end

    it "reports locked? for either kind of lock" do
      LockClauseSpecItem.where(id: 1).locked?.should be_false
      LockClauseSpecItem.lock.locked?.should be_true
      LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).locked?.should be_true
      LockClauseSpecItem.lock.unlock.locked?.should be_false
    end

    it "leaves a relation that was never locked untouched" do
      LockClauseSpecItem.where(id: 1).unlock.lock_mode.should be_nil
    end
  end

  describe "merge and structural comparison" do
    it "keeps the receiver's lock when the other relation has none" do
      merged = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).merge(LockClauseSpecItem.where(id: 1))
      merged.lock_clause.should eq(LOCK_CLAUSE_SPEC_NO_KEY)
    end

    it "takes the other relation's mode over a clause" do
      merged = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).merge(LockClauseSpecItem.lock(Grant::Locking::LockMode::Share))
      merged.lock_clause.should be_nil
      merged.lock_mode.should eq(Grant::Locking::LockMode::Share)
    end

    it "treats two different clauses as incompatible for and/or" do
      first = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_NO_KEY).where(id: 1)
      second = LockClauseSpecItem.lock(LOCK_CLAUSE_SPEC_OF).where(id: 2)
      expect_raises(ArgumentError) { first.or(second) }
    end
  end
end
