require "../../spec_helper"
require "../../support/write_sql_capture"
require "../dirty/dirty_family_models"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class PartialNote < Grant::Base
    connection {{ adapter_literal }}
    table partial_notes

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column views : Int32?
    column slug : String?
    timestamps

    attr_readonly :slug
    property before_save_runs : Int32 = 0
    before_save :count_before_save

    private def count_before_save
      @before_save_runs += 1
    end
  end

  class PartialLegacyNote < Grant::Base
    connection {{ adapter_literal }}
    table partial_legacy_notes

    column id : Int64, primary: true
    column title : String?
    column body : String?
    timestamps

    partial_updates false
  end
{% end %}

PartialNote.migrator.drop_and_create
PartialLegacyNote.migrator.drop_and_create

private def updates_in(statements : Array(String)) : Array(String)
  statements.select(&.match(/\A\[[^\]]*\]\s+UPDATE\b/i))
end

describe "Partial updates" do
  before_each do
    PartialNote.clear
    PartialLegacyNote.clear
  end

  it "writes only the changed column, so a stale sibling column is not overwritten" do
    note = PartialNote.create!(title: "first", body: "original body", views: 1)

    left = PartialNote.find!(note.id)
    right = PartialNote.find!(note.id)

    left.title = "edited by left"
    left.save!

    # `right` still holds the old title and body; only `body` is changed here.
    right.body = "edited by right"
    statements = WriteSqlCapture.statements { right.save! }
    updates_in(statements).size.should eq(1)
    updates_in(statements).first.should_not contain("title")
    updates_in(statements).first.should contain("body")

    reloaded = PartialNote.find!(note.id)
    reloaded.title.should eq("edited by left")
    reloaded.body.should eq("edited by right")
  end

  it "issues no SQL for a clean save and does not bump updated_at" do
    note = PartialNote.create!(title: "clean")
    reloaded = PartialNote.find!(note.id)
    stamp = reloaded.updated_at

    sleep 5.milliseconds
    statements = WriteSqlCapture.statements { reloaded.save.should be_true }
    updates_in(statements).should be_empty
    reloaded.updated_at.should eq(stamp)
    PartialNote.find!(note.id).updated_at.should eq(stamp)
  end

  it "still runs save callbacks when there is nothing to write" do
    note = PartialNote.create!(title: "callbacks")
    reloaded = PartialNote.find!(note.id)
    reloaded.save!
    reloaded.before_save_runs.should eq(1)
  end

  it "adds updated_at to the changed columns" do
    note = PartialNote.create!(title: "stamp")
    reloaded = PartialNote.find!(note.id)
    stamp = reloaded.updated_at.not_nil!

    sleep 5.milliseconds
    reloaded.title = "stamped"
    statements = WriteSqlCapture.statements { reloaded.save! }
    updates_in(statements).first.should contain("updated_at")
    PartialNote.find!(note.id).updated_at.not_nil!.should be > stamp
  end

  it "leaves updated_at out when skip_timestamps is set" do
    note = PartialNote.create!(title: "skip")
    reloaded = PartialNote.find!(note.id)
    reloaded.title = "skipped"
    statements = WriteSqlCapture.statements { reloaded.save!(skip_timestamps: true) }
    updates_in(statements).first.should_not contain("updated_at")
  end

  it "never rewrites created_at or a readonly column" do
    note = PartialNote.create!(title: "guarded", slug: "keep-me")
    reloaded = PartialNote.find!(note.id)
    reloaded.title = "changed"
    statements = WriteSqlCapture.statements { reloaded.save! }
    updates_in(statements).first.should_not contain("created_at")
    updates_in(statements).first.should_not contain("slug")
  end

  it "opts out per model with partial_updates false" do
    note = PartialLegacyNote.create!(title: "legacy", body: "b")
    reloaded = PartialLegacyNote.find!(note.id)

    reloaded.title = "changed"
    statements = WriteSqlCapture.statements { reloaded.save! }
    updates_in(statements).first.should contain("body")

    stale = PartialLegacyNote.find!(note.id)
    stale.body = "changed body"
    stale.save!
    reloaded.title = "again"
    reloaded.save!
    PartialLegacyNote.find!(note.id).body.should eq("b")
  end

  it "reports partial updates as the default" do
    PartialNote.partial_updates?.should be_true
    PartialLegacyNote.partial_updates?.should be_false
  end

  describe "serialized columns" do
    it "writes a serialized object mutated in place" do
      record = F01PlainPrefs.new
      record.prefs = F01Settings.new("dark", ["one"])
      record.save!
      reloaded = F01PlainPrefs.find!(record.id)
      reloaded.prefs.not_nil!.theme = "solarized"
      reloaded.save!

      F01PlainPrefs.find!(record.id).prefs.not_nil!.theme.should eq("solarized")
    end

    it "issues no SQL when the serialized object was only read" do
      record = F01PlainPrefs.new
      record.prefs = F01Settings.new("dark")
      record.save!
      reloaded = F01PlainPrefs.find!(record.id)
      reloaded.prefs.not_nil!.theme.should eq("dark")
      statements = WriteSqlCapture.statements { reloaded.save! }
      updates_in(statements).should be_empty
    end

    it "keeps the in-place edit when mutation detection is on" do
      record = F01Prefs.new(title: "t")
      record.prefs = F01Settings.new("dark")
      record.save!
      reloaded = F01Prefs.find!(record.id)
      reloaded.prefs.not_nil!.items << "x"
      reloaded.save!

      F01Prefs.find!(record.id).prefs.not_nil!.items.should eq(["x"])
    end
  end

  if CURRENT_ADAPTER == "pg"
    describe "array columns" do
      it "keeps writing every column when in-place mutation is not watched" do
        record = F01Tagged.create!(title: "t", tags: ["a"])
        reloaded = F01Tagged.find!(record.id)
        reloaded.tags.not_nil! << "b"
        reloaded.save!

        F01Tagged.find!(record.id).tags.should eq(["a", "b"])
      end

      it "skips a clean save and writes a watched in-place edit" do
        record = F01Watched.create!(title: "t", tags: ["a"])
        reloaded = F01Watched.find!(record.id)
        updates_in(WriteSqlCapture.statements { reloaded.save! }).should be_empty

        reloaded.tags.not_nil! << "b"
        reloaded.save!
        F01Watched.find!(record.id).tags.should eq(["a", "b"])
      end
    end
  end
end
