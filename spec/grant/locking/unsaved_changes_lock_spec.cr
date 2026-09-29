require "../../spec_helper"

{% begin %}
{% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}
class UnsavedLockSpecNote < Grant::Base
  connection {{adapter_literal}}
  table unsaved_lock_spec_notes

  column id : Int64, primary: true
  column title : String
  column body : String?
end
{% end %}

UnsavedLockSpecNote.migrator.drop_and_create

describe "locking a record with unsaved changes" do
  before_each { UnsavedLockSpecNote.clear }

  it "raises UnsavedChangesLockError from lock! and leaves the changes alone" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.title = "Edited"

    UnsavedLockSpecNote.transaction do
      expect_raises(Grant::UnsavedChangesLockError, "unsaved changes") { note.lock! }
    end

    note.title.should eq("Edited")
    note.changed?.should be_true
  end

  it "is the same error under the Locking namespace" do
    Grant::Locking::UnsavedChangesError.should eq(Grant::UnsavedChangesLockError)
    Grant::UnsavedChangesLockError.new.is_a?(Grant::ErrorBase).should be_true
  end

  it "raises from reload_with_lock and from every lock mode" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.body = "draft"

    UnsavedLockSpecNote.transaction do
      expect_raises(Grant::UnsavedChangesLockError) { note.reload_with_lock }
      expect_raises(Grant::UnsavedChangesLockError) { note.lock!(Grant::Locking::LockMode::Share) }
      expect_raises(Grant::UnsavedChangesLockError) { note.lock!(Grant::Locking.clause("FOR UPDATE")) }
    end
  end

  it "raises from with_lock without opening a transaction's worth of work" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.title = "Edited"
    ran = false

    expect_raises(Grant::UnsavedChangesLockError) do
      note.with_lock { |_locked| ran = true }
    end

    ran.should be_false
    UnsavedLockSpecNote.find!(note.id).title.should eq("Original")
  end

  it "discards the changes and locks the fresh row with force: true" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.title = "Edited"

    UnsavedLockSpecNote.transaction do
      note.lock!(force: true).should be(note)
    end

    note.title.should eq("Original")
    note.changed?.should be_false
  end

  it "supports force: true on with_lock" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.title = "Edited"

    title = note.with_lock(force: true) { |locked| locked.title }

    title.should eq("Original")
    note.changed?.should be_false
  end

  it "locks a clean record without complaint" do
    note = UnsavedLockSpecNote.create!(title: "Original")

    UnsavedLockSpecNote.transaction do
      note.lock!.should be(note)
    end
    note.with_lock { |locked| locked.title }.should eq("Original")
  end

  it "treats a record whose change was undone as clean" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.title = "Edited"
    note.title = "Original"

    UnsavedLockSpecNote.transaction { note.lock! }
  end

  it "counts a saved change as clean and an unsaved one after it as dirty" do
    note = UnsavedLockSpecNote.create!(title: "Original")
    note.update!(title: "Saved")
    UnsavedLockSpecNote.transaction { note.lock! }

    note.body = "Not saved"
    UnsavedLockSpecNote.transaction do
      expect_raises(Grant::UnsavedChangesLockError) { note.lock! }
    end
  end
end
