require "spec"
require "../../../../src/grant/sqlite_engine"

private def in_memory_session : Grant::SQLiteEngine::Query::Session
  pager = Grant::SQLiteEngine::Pager.open_read_write(Grant::SQLiteEngine::MemoryFileSystem.new, ":memory:")
  Grant::SQLiteEngine::Query::Session.new(Grant::SQLiteEngine::Database.new(pager))
end

private def changes_after(session : Grant::SQLiteEngine::Query::Session, sql : String) : Int64
  query = session.prepare(sql)
  while query.step
  end
  session.changes
end

describe Grant::SQLiteEngine::Query::WriteRun do
  describe "#restart" do
    it "gives a finished run the state of a new run" do
      session = in_memory_session
      parameters = [1_i64] of Grant::SQLiteEngine::Value
      run = Grant::SQLiteEngine::Query::WriteRun.new(session, [] of Grant::SQLiteEngine::Value)
      run.changes = 7_i64
      run.single_row = true
      run.silent = true
      run.immediate_violations = 3_i64
      run.nested = 2
      run.triggers_disabled = true
      run.autocommit = true

      run.restart(parameters).should be(run)
      fresh = Grant::SQLiteEngine::Query::WriteRun.new(session, parameters)
      run.list_of_parameters.should be(parameters)
      run.session.should be(session)
      run.changes.should eq(fresh.changes)
      run.single_row?.should eq(fresh.single_row?)
      run.statement_journal?.should eq(fresh.statement_journal?)
      run.autocommit?.should eq(fresh.autocommit?)
      run.silent?.should eq(fresh.silent?)
      run.immediate_violations.should eq(fresh.immediate_violations)
      run.nested.should eq(fresh.nested)
      run.trigger_depth.should eq(fresh.trigger_depth)
      run.triggers_disabled?.should eq(fresh.triggers_disabled?)
      run.trigger_programs.should be_nil
    end
  end

  it "counts each write statement's changes on its own when the session reuses its run" do
    session = in_memory_session
    changes_after(session, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)")
    changes_after(session, "INSERT INTO t (v) VALUES ('a'), ('b'), ('c')").should eq(3)
    changes_after(session, "INSERT INTO t (v) VALUES ('d')").should eq(1)
    expect_raises(Grant::SQLiteEngine::SQLError, /UNIQUE constraint failed/) do
      changes_after(session, "INSERT INTO t (v) VALUES ('e'), ('a')")
    end
    changes_after(session, "UPDATE t SET v = v || '!' WHERE id <= 2").should eq(2)
    changes_after(session, "DELETE FROM t WHERE id = 4").should eq(1)
    query = session.prepare("SELECT group_concat(v, ',') FROM t ORDER BY id")
    query.step.should be_true
    query.row.should eq(["a!,b!,c"] of Grant::SQLiteEngine::Value)
  end
end
