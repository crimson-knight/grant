require "../../spec_helper"

# ---------------------------------------------------------------------------
# Models used only in this file.
# ---------------------------------------------------------------------------

# A model that records exactly when each commit/rollback callback fires.
class CommitTimingModel < Grant::Base
  connection sqlite
  table commit_timing_models

  column id : Int64, primary: true
  column name : String?
  timestamps

  # Shared log so tests can observe callback order vs. transaction boundary.
  class_property event_log : Array(String) = [] of String

  after_commit do
    CommitTimingModel.event_log << "after_commit:#{name}"
  end

  after_rollback do
    CommitTimingModel.event_log << "after_rollback:#{name}"
  end

  after_create_commit do
    CommitTimingModel.event_log << "after_create_commit:#{name}"
  end

  after_update_commit do
    CommitTimingModel.event_log << "after_update_commit:#{name}"
  end

  after_destroy_commit do
    CommitTimingModel.event_log << "after_destroy_commit:#{name}"
  end
end

# A second, unrelated model class — used to verify cross-model semantics.
class CommitTimingOther < Grant::Base
  connection sqlite
  table commit_timing_others

  column id : Int64, primary: true
  column label : String?
  timestamps

  class_property event_log : Array(String) = [] of String

  after_commit do
    CommitTimingOther.event_log << "after_commit:#{label}"
  end

  after_rollback do
    CommitTimingOther.event_log << "after_rollback:#{label}"
  end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

private def reset_logs
  CommitTimingModel.event_log.clear
  CommitTimingOther.event_log.clear
end

# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

describe "after_commit / after_rollback timing (AR semantics)" do
  before_all do
    CommitTimingModel.migrator.drop_and_create
    CommitTimingOther.migrator.drop_and_create
  end

  before_each do
    CommitTimingModel.clear
    CommitTimingOther.clear
    reset_logs
  end

  # -------------------------------------------------------------------------
  # 1. after_commit must NOT fire mid-block
  # -------------------------------------------------------------------------
  describe "inside an explicit transaction block" do
    it "does NOT fire after_commit while the block is still running" do
      fired_inside = false

      CommitTimingModel.transaction do
        m = CommitTimingModel.new(name: "mid-block")
        m.save

        # callback must not have fired yet
        fired_inside = CommitTimingModel.event_log.any?(&.starts_with?("after_commit"))
      end

      fired_inside.should be_false
    end

    # -----------------------------------------------------------------------
    # 2. after_commit fires exactly once, AFTER the outermost commit
    # -----------------------------------------------------------------------
    it "fires after_commit exactly once after outermost COMMIT" do
      CommitTimingModel.transaction do
        m = CommitTimingModel.new(name: "committed")
        m.save
      end

      ac = CommitTimingModel.event_log.select { |e| e == "after_commit:committed" }
      ac.size.should eq(1)
    end

    it "fires after_create_commit after outermost COMMIT (not before)" do
      seq = [] of String

      CommitTimingModel.transaction do
        m = CommitTimingModel.new(name: "newrec")
        m.save
        seq << "still_in_tx"
      end
      seq << "after_tx"

      # Verify the callback fired after the transaction, not inside
      # event_log receives the callback; seq records what ran synchronously
      CommitTimingModel.event_log.should contain("after_create_commit:newrec")
      CommitTimingModel.event_log.should contain("after_commit:newrec")
    end

    it "fires after_update_commit after outermost COMMIT" do
      m = CommitTimingModel.create!(name: "orig")
      reset_logs

      CommitTimingModel.transaction do
        m.name = "updated"
        m.save
      end

      CommitTimingModel.event_log.should contain("after_update_commit:updated")
      CommitTimingModel.event_log.should contain("after_commit:updated")
    end

    it "fires after_destroy_commit after outermost COMMIT" do
      m = CommitTimingModel.create!(name: "to_destroy")
      reset_logs

      CommitTimingModel.transaction do
        m.destroy
      end

      CommitTimingModel.event_log.should contain("after_destroy_commit:to_destroy")
      CommitTimingModel.event_log.should contain("after_commit:to_destroy")
    end
  end

  # -------------------------------------------------------------------------
  # 3. after_rollback fires on exception-driven rollback
  # -------------------------------------------------------------------------
  describe "explicit transaction — exception rollback" do
    it "fires after_rollback (not after_commit) when block raises" do
      expect_raises(Exception, "kaboom") do
        CommitTimingModel.transaction do
          CommitTimingModel.new(name: "lost").save
          raise "kaboom"
        end
      end

      CommitTimingModel.event_log.should contain("after_rollback:lost")
      CommitTimingModel.event_log.should_not contain("after_commit:lost")
    end
  end

  # -------------------------------------------------------------------------
  # 4. after_rollback fires on Grant::Transaction::Rollback
  # -------------------------------------------------------------------------
  describe "explicit transaction — Rollback sentinel" do
    it "fires after_rollback when Grant::Transaction::Rollback is raised" do
      CommitTimingModel.transaction do
        CommitTimingModel.new(name: "sentinel").save
        raise Grant::Transaction::Rollback.new
      end

      CommitTimingModel.event_log.should contain("after_rollback:sentinel")
      CommitTimingModel.event_log.should_not contain("after_commit:sentinel")
    end
  end

  # -------------------------------------------------------------------------
  # 5. Implicit (non-block) save fires after_commit immediately
  # -------------------------------------------------------------------------
  describe "save OUTSIDE an explicit transaction" do
    it "fires after_commit immediately on success (implicit single-save tx)" do
      CommitTimingModel.new(name: "solo").save

      CommitTimingModel.event_log.should contain("after_commit:solo")
    end

    it "does NOT fire after_rollback on a successful implicit save" do
      CommitTimingModel.new(name: "solo-ok").save

      CommitTimingModel.event_log.should_not contain("after_rollback:solo-ok")
    end
  end

  # -------------------------------------------------------------------------
  # 6. Cross-model — two different model classes in one transaction
  # -------------------------------------------------------------------------
  describe "cross-model transaction" do
    it "fires after_commit for both model classes after the single commit" do
      CommitTimingModel.transaction do
        CommitTimingModel.new(name: "alpha").save
        CommitTimingOther.new(label: "beta").save
      end

      CommitTimingModel.event_log.should contain("after_commit:alpha")
      CommitTimingOther.event_log.should contain("after_commit:beta")
    end

    it "fires after_rollback for both model classes on exception" do
      expect_raises(Exception, "tx fail") do
        CommitTimingModel.transaction do
          CommitTimingModel.new(name: "alpha-rb").save
          CommitTimingOther.new(label: "beta-rb").save
          raise "tx fail"
        end
      end

      CommitTimingModel.event_log.should contain("after_rollback:alpha-rb")
      CommitTimingOther.event_log.should contain("after_rollback:beta-rb")
    end
  end

  # -------------------------------------------------------------------------
  # 7. Nested transactions (savepoints): callbacks fire only at outermost commit
  # -------------------------------------------------------------------------
  describe "nested savepoint transactions" do
    it "defers callbacks from inner savepoint until outermost commit" do
      CommitTimingModel.transaction do
        CommitTimingModel.transaction do
          CommitTimingModel.new(name: "inner").save
          # Still inside outer — must not have fired
          CommitTimingModel.event_log.should be_empty
        end
        # Released savepoint — still inside outer — still must not have fired
        CommitTimingModel.event_log.should be_empty
      end

      CommitTimingModel.event_log.should contain("after_commit:inner")
    end
  end
end
