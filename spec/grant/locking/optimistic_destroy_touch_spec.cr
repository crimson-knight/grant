require "../../spec_helper"
require "../../../src/grant/spec_support/*"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class OptimisticDestroyTouchSpecDoc < Grant::Base
  connection {{adapter_literal}}
  table optimistic_destroy_touch_spec_docs

  include Grant::Locking::Optimistic

  column id : Int64, primary: true
  column title : String
  column reviewed_at : Time?
  timestamps
end
{% end %}

OptimisticDestroyTouchSpecDoc.migrator.drop_and_create

private alias StaleError = Grant::Locking::Optimistic::StaleObjectError

describe "Optimistic locking on destroy and touch" do
  before_each { OptimisticDestroyTouchSpecDoc.clear }

  describe "#destroy" do
    it "raises StaleObjectError for a copy another writer has updated, and keeps the row" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")

      error = expect_raises(StaleError, "Attempted to destroy a stale OptimisticDestroyTouchSpecDoc") { stale.destroy }
      error.record_class.should eq("OptimisticDestroyTouchSpecDoc")
      error.record_id.should eq(doc.id.to_s)

      stale.destroyed?.should be_false
      OptimisticDestroyTouchSpecDoc.find!(doc.id).title.should eq("v1")
    end

    it "raises from destroy! as StaleObjectError, not as a failed-destroy error" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")

      expect_raises(StaleError) { stale.destroy! }
    end

    it "raises when the row was already deleted by someone else" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      OptimisticDestroyTouchSpecDoc.where(id: doc.id).delete_all

      expect_raises(StaleError) { doc.destroy }
      doc.destroyed?.should be_false
    end

    it "destroys a record loaded at a version above zero" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      doc.update!(title: "v1")
      doc.update!(title: "v2")

      loaded = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      loaded.lock_version.should eq(2)
      loaded.destroy.should be_true
      OptimisticDestroyTouchSpecDoc.exists?(doc.id).should be_false
    end

    it "destroys the writer's own copy after its saves" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      doc.update!(title: "v1")
      doc.destroy.should be_true
      doc.destroyed?.should be_true
    end

    it "rides the primary-key DELETE: one statement, version in the WHERE, no pre-read" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      doc.update!(title: "v1")
      loaded = OptimisticDestroyTouchSpecDoc.find!(doc.id)

      queries = Grant::Spec.capture_queries { loaded.destroy }

      statements = queries.map(&.sql).reject { |sql| sql =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i }
      statements.none?(&.starts_with?("SELECT")).should be_true
      deletes = statements.select(&.starts_with?("DELETE"))
      deletes.size.should eq(1)
      deletes.first.should contain("lock_version")
    end

    it "lets the caller reload and destroy after a stale failure" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")

      expect_raises(StaleError) { stale.destroy }
      stale.reload.destroy.should be_true
      OptimisticDestroyTouchSpecDoc.exists?(doc.id).should be_false
    end

    it "retries through with_optimistic_retry" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")

      stale.with_optimistic_retry(1) { stale.destroy }
      OptimisticDestroyTouchSpecDoc.exists?(doc.id).should be_false
    end

    it "does not run the after_destroy-side effects when the destroy is stale" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")

      expect_raises(StaleError) { stale.destroy }
      stale.destroyed?.should be_false
      stale.persisted?.should be_true
    end
  end

  describe "#touch" do
    it "bumps lock_version along with updated_at" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      before = OptimisticDestroyTouchSpecDoc.find!(doc.id).updated_at.not_nil!

      sleep 5.milliseconds
      doc.touch.should be_true

      doc.lock_version.should eq(1)
      row = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      row.lock_version.should eq(1)
      row.updated_at.not_nil!.should be > before
    end

    it "bumps once per touch and keeps later saves in step" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      doc.touch
      doc.touch(:reviewed_at)
      doc.lock_version.should eq(2)

      doc.update!(title: "v1")
      doc.lock_version.should eq(3)
      OptimisticDestroyTouchSpecDoc.find!(doc.id).lock_version.should eq(3)
      OptimisticDestroyTouchSpecDoc.find!(doc.id).reviewed_at.should_not be_nil
    end

    it "raises StaleObjectError for a stale copy and writes nothing" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      stale = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update!(title: "v1")
      updated_at = OptimisticDestroyTouchSpecDoc.find!(doc.id).updated_at

      sleep 5.milliseconds
      expect_raises(StaleError, "stale OptimisticDestroyTouchSpecDoc") { stale.touch }

      row = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      row.lock_version.should eq(1)
      row.updated_at.should eq(updated_at)
    end

    it "makes an older copy stale, so a touch and a save cannot silently overwrite each other" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      editor = OptimisticDestroyTouchSpecDoc.find!(doc.id)

      doc.touch

      editor.title = "edited"
      expect_raises(StaleError) { editor.save! }
    end

    it "does nothing at all while touching is suppressed" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      OptimisticDestroyTouchSpecDoc.no_touching { doc.touch }
      OptimisticDestroyTouchSpecDoc.find!(doc.id).lock_version.should eq(0)
    end

    it "still refuses to touch an unsaved record with the usual error" do
      expect_raises(Exception, "Cannot touch on a new record object") do
        OptimisticDestroyTouchSpecDoc.new(title: "new").touch
      end
    end
  end

  describe "the bulk and column-level writers" do
    it "leaves lock_version alone for update_columns, as ActiveRecord does" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      doc.update_columns(title: "direct")

      doc.lock_version.should eq(0)
      row = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      row.title.should eq("direct")
      row.lock_version.should eq(0)
    end

    it "does not check or bump the version for update_all" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      OptimisticDestroyTouchSpecDoc.where(id: doc.id).update_all(title: "bulk")

      row = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      row.title.should eq("bulk")
      row.lock_version.should eq(0)
    end

    it "does not make a copy stale when only update_columns ran" do
      doc = OptimisticDestroyTouchSpecDoc.create!(title: "v0")
      other = OptimisticDestroyTouchSpecDoc.find!(doc.id)
      doc.update_columns(title: "direct")

      other.title = "saved"
      other.save!
      OptimisticDestroyTouchSpecDoc.find!(doc.id).lock_version.should eq(1)
    end
  end

  describe ".locking_enabled?" do
    it "is true for a model with the module" do
      OptimisticDestroyTouchSpecDoc.locking_enabled?.should be_true
    end
  end
end
