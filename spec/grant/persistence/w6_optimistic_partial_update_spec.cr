require "../../spec_helper"
require "../../support/composite_sql_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6LockedNote < Grant::Base
    connection {{ adapter_literal }}
    table w6_locked_notes

    include Grant::Locking::Optimistic

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column views : Int32?
    timestamps
  end

  class W6LockedLegacyNote < Grant::Base
    connection {{ adapter_literal }}
    table w6_locked_legacy_notes

    include Grant::Locking::Optimistic

    column id : Int64, primary: true
    column title : String?
    column body : String?

    partial_updates false
  end
{% end %}

W6LockedNote.migrator.drop_and_create
W6LockedLegacyNote.migrator.drop_and_create

private def w6_updates_in(statements : Array(String)) : Array(String)
  statements.select(&.match(/\A\s*UPDATE\b/i))
end

describe "Optimistic locking with partial updates" do
  before_each do
    W6LockedNote.clear
    W6LockedLegacyNote.clear
  end

  it "issues no SQL for a clean save and keeps lock_version and updated_at" do
    note = W6LockedNote.create!(title: "clean", body: "b")
    loaded = W6LockedNote.find!(note.id)
    stamp = loaded.updated_at
    version = loaded.lock_version

    sleep 5.milliseconds
    statements = capture_statements { loaded.save!.should be_true }
    statements.should be_empty
    loaded.lock_version.should eq(version)
    loaded.updated_at.should eq(stamp)

    stored = W6LockedNote.find!(note.id)
    stored.lock_version.should eq(version)
    stored.updated_at.should eq(stamp)
  end

  it "does not raise for a clean save even when the row has moved on" do
    note = W6LockedNote.create!(title: "t")
    stale = W6LockedNote.find!(note.id)

    other = W6LockedNote.find!(note.id)
    other.title = "moved on"
    other.save!

    stale.save!.should be_true
    W6LockedNote.find!(note.id).title.should eq("moved on")
  end

  it "writes only the changed column plus the version and updated_at" do
    note = W6LockedNote.create!(title: "t", body: "original", views: 1)
    loaded = W6LockedNote.find!(note.id)
    loaded.body = "edited"

    statements = capture_statements { loaded.save! }
    updates = w6_updates_in(statements)
    updates.size.should eq(1)
    updates.first.should contain("body")
    updates.first.should contain("lock_version")
    updates.first.should contain("updated_at")
    updates.first.should_not contain("title")
    updates.first.should_not contain("views")
    loaded.lock_version.should eq(1)
  end

  it "does not overwrite a stale sibling column" do
    note = W6LockedNote.create!(title: "t", body: "b")
    left = W6LockedNote.find!(note.id)
    right = W6LockedNote.find!(note.id)

    left.title = "left"
    left.save!
    right.reload
    right.body = "right"
    right.save!

    stored = W6LockedNote.find!(note.id)
    stored.title.should eq("left")
    stored.body.should eq("right")
    stored.lock_version.should eq(2)
  end

  it "still detects a conflicting write" do
    note = W6LockedNote.create!(title: "t", body: "b")
    left = W6LockedNote.find!(note.id)
    right = W6LockedNote.find!(note.id)

    left.title = "left"
    left.save!

    right.body = "right"
    expect_raises(Grant::Locking::Optimistic::StaleObjectError) { right.save! }
  end

  it "keeps the legacy full-row write for partial_updates false" do
    note = W6LockedLegacyNote.create!(title: "t", body: "b")
    loaded = W6LockedLegacyNote.find!(note.id)
    loaded.body = "edited"

    statements = capture_statements { loaded.save! }
    updates = w6_updates_in(statements)
    updates.size.should eq(1)
    updates.first.should contain("title")
  end
end
