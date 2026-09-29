require "../../spec_helper"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class LockWaitSpecJob < Grant::Base
  connection {{adapter_literal}}
  table lock_wait_spec_jobs

  column id : Int64, primary: true
  column state : String
end
{% end %}

LockWaitSpecJob.migrator.drop_and_create

# Holds a row lock in a second fiber (so on a second connection) while the
# block runs, then lets that fiber commit.
private def lock_wait_spec_holding(id : Int64, mode : Grant::Locking::LockMode = Grant::Locking::LockMode::Update, &)
  held = Channel(Nil).new
  release = Channel(Nil).new
  finished = Channel(Exception?).new

  spawn do
    failure = nil
    begin
      LockWaitSpecJob.transaction do
        LockWaitSpecJob.where(id: id).lock(mode).first!
        held.send(nil)
        release.receive
      end
    rescue ex
      failure = ex
    end
    finished.send(failure)
  end

  select
  when held.receive
  when timeout(10.seconds)
    raise "the lock holder never took its lock"
  end

  begin
    yield
  ensure
    release.send(nil)
    failure = finished.receive
    raise failure if failure
  end
end

private def lock_wait_spec_real_locks? : Bool
  LockWaitSpecJob.adapter.supports_lock_mode?(Grant::Locking::LockMode::Update)
end

describe "Row lock waits" do
  before_each { LockWaitSpecJob.clear }

  describe "SQL and single-connection behavior (every adapter)" do
    it "renders each lock mode for the adapter, and nothing on SQLite" do
      {
        Grant::Locking::LockMode::UpdateNoWait     => "FOR UPDATE NOWAIT",
        Grant::Locking::LockMode::UpdateSkipLocked => "FOR UPDATE SKIP LOCKED",
      }.each do |mode, expected|
        sql = LockWaitSpecJob.where(id: 1).lock(mode).to_sql
        if lock_wait_spec_real_locks?
          sql.should end_with(expected)
        else
          sql.should_not contain("FOR ")
          sql.should_not contain("NOWAIT")
          sql.should_not contain("SKIP LOCKED")
        end
      end
    end

    it "returns the row on the same connection: a lock never blocks its own transaction" do
      job = LockWaitSpecJob.create!(state: "queued")

      LockWaitSpecJob.transaction do
        LockWaitSpecJob.where(id: job.id).lock.first!.state.should eq("queued")
        LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateNoWait).first!.state.should eq("queued")
        LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateSkipLocked).first!.state.should eq("queued")
      end
    end
  end

  if lock_wait_spec_real_locks?
    describe "with real row locks" do
      it "raises LockWaitTimeout for NOWAIT on a row another connection holds" do
        job = LockWaitSpecJob.create!(state: "queued")
        lock_wait_spec_holding(job.id!) do
          LockWaitSpecJob.transaction do
            error = expect_raises(Grant::LockWaitTimeout) do
              LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateNoWait).first!
            end
            error.cause.should_not be_nil
            error.sql.to_s.should contain("NOWAIT")
          end
        end
      end

      it "is the same class the Locking namespace names" do
        Grant::Locking::LockWaitTimeoutError.should eq(Grant::LockWaitTimeout)
      end

      it "raises LockWaitTimeout from with_lock and lock! in NOWAIT mode, leaving the record untouched" do
        job = LockWaitSpecJob.create!(state: "queued")
        lock_wait_spec_holding(job.id!) do
          expect_raises(Grant::LockWaitTimeout) do
            job.with_lock(Grant::Locking::LockMode::UpdateNoWait) { |_locked| :never }
          end

          LockWaitSpecJob.transaction do
            expect_raises(Grant::LockWaitTimeout) { job.lock!(Grant::Locking::LockMode::UpdateNoWait) }
          end
        end
        job.state.should eq("queued")
      end

      it "hands a free row to SKIP LOCKED callers and skips the held one" do
        first = LockWaitSpecJob.create!(state: "first")
        second = LockWaitSpecJob.create!(state: "second")

        lock_wait_spec_holding(first.id!) do
          LockWaitSpecJob.transaction do
            picked = LockWaitSpecJob.order(:id).lock(Grant::Locking::LockMode::UpdateSkipLocked).first!
            picked.id.should eq(second.id)
          end
        end
      end

      it "returns nothing from SKIP LOCKED when every row is held" do
        only = LockWaitSpecJob.create!(state: "only")

        lock_wait_spec_holding(only.id!) do
          LockWaitSpecJob.transaction do
            LockWaitSpecJob.lock(Grant::Locking::LockMode::UpdateSkipLocked).first.should be_nil
            LockWaitSpecJob.lock(Grant::Locking::LockMode::UpdateSkipLocked).to_a.should be_empty
          end
        end
      end

      it "makes a plain FOR UPDATE wait until the holder commits" do
        job = LockWaitSpecJob.create!(state: "queued")
        events = [] of String
        waiter_done = Channel(Nil).new

        lock_wait_spec_holding(job.id!) do
          spawn do
            LockWaitSpecJob.transaction do
              LockWaitSpecJob.where(id: job.id).lock.first!
              events << "waiter got the lock"
            end
            waiter_done.send(nil)
          end

          sleep 150.milliseconds
          events << "holder still holds"
          events.should eq(["holder still holds"])
        end

        select
        when waiter_done.receive
        when timeout(10.seconds)
          raise "the waiter never got the lock"
        end
        events.should eq(["holder still holds", "waiter got the lock"])
      end

      it "lets FOR SHARE readers share and blocks a NOWAIT writer" do
        job = LockWaitSpecJob.create!(state: "queued")
        lock_wait_spec_holding(job.id!, Grant::Locking::LockMode::Share) do
          LockWaitSpecJob.transaction do
            LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::Share).first!.state.should eq("queued")
            expect_raises(Grant::LockWaitTimeout) do
              LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateNoWait).first!
            end
          end
        end
      end

      it "releases the lock when the holder commits, so a later NOWAIT succeeds" do
        job = LockWaitSpecJob.create!(state: "queued")
        lock_wait_spec_holding(job.id!) { }

        LockWaitSpecJob.transaction do
          LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateNoWait).first!.state.should eq("queued")
        end
      end
    end
  else
    describe "without row locks (SQLite)" do
      it "treats NOWAIT and SKIP LOCKED as no-ops: another connection's lock never blocks or hides a row" do
        job = LockWaitSpecJob.create!(state: "queued")

        lock_wait_spec_holding(job.id!) do
          LockWaitSpecJob.transaction do
            nowait = LockWaitSpecJob.where(id: job.id).lock(Grant::Locking::LockMode::UpdateNoWait).first!
            nowait.state.should eq("queued")
            skipped = LockWaitSpecJob.lock(Grant::Locking::LockMode::UpdateSkipLocked).to_a
            skipped.map(&.id).should eq([job.id])
          end
        end
      end

      it "runs with_lock in NOWAIT mode without raising" do
        job = LockWaitSpecJob.create!(state: "queued")
        job.with_lock(Grant::Locking::LockMode::UpdateNoWait) { |locked| locked.state }.should eq("queued")
      end
    end
  end
end
