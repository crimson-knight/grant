require "json"
require "../../spec_helper"
require "../../support/composite_sql_recorder"
require "./dirty_family_models"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # Array column with no detect_mutation: still partial-update safe.
  class W6ArrayNote < Grant::Base
    connection {{ adapter_literal }}
    table w6_array_notes

    column id : Int64, primary: true
    column title : String?
    column body : String?
    column tags : Array(String)?
  end

  # Hash and JSON document columns, watched through detect_mutation.
  class W6DocNote < Grant::Base
    connection {{ adapter_literal }}
    table w6_doc_notes

    column id : Int64, primary: true
    column title : String?
    column options : Hash(String, String)?, converter: Grant::Converters::Json(Hash(String, String), String), column_type: "TEXT"
    column payload : JSON::Any?, column_type: "TEXT"

    detect_mutation
  end

  class W6DocPlain < Grant::Base
    connection {{ adapter_literal }}
    table w6_doc_plains

    column id : Int64, primary: true
    column options : Hash(String, String)?, converter: Grant::Converters::Json(Hash(String, String), String), column_type: "TEXT"
  end
{% end %}

# Array columns exist on PostgreSQL only.
W6ArrayNote.migrator.drop_and_create if CURRENT_ADAPTER == "pg"
W6DocNote.migrator.drop_and_create
W6DocPlain.migrator.drop_and_create

private def w6_updates(statements : Array(String)) : Array(String)
  statements.select(&.match(/\A\s*UPDATE\b/i))
end

describe "Mutation watching" do
  before_each do
    W6ArrayNote.clear if CURRENT_ADAPTER == "pg"
    W6DocNote.clear
    W6DocPlain.clear
    F01PlainPrefs.clear
  end

  describe "Array columns without detect_mutation" do
    it "detects an in-place edit in memory on every adapter" do
      note = W6ArrayNote.new(title: "t", tags: ["a"])
      note.changed?.should be_false
      note.tags.not_nil! << "b"
      note.changed?.should be_true
    end

    if CURRENT_ADAPTER == "pg"
      it "issues no SQL for a clean save" do
        note = W6ArrayNote.create!(title: "t", tags: ["a"])
        loaded = W6ArrayNote.find!(note.id)
        capture_statements { loaded.save! }.should be_empty
      end

      it "writes only the edited Array column and no stale sibling" do
        note = W6ArrayNote.create!(title: "t", body: "b", tags: ["a"])
        left = W6ArrayNote.find!(note.id)
        right = W6ArrayNote.find!(note.id)

        left.title = "left"
        left.save!

        right.tags.not_nil! << "b"
        updates = w6_updates(capture_statements { right.save! })
        updates.size.should eq(1)
        updates.first.should contain("tags")
        updates.first.should_not contain("title")

        stored = W6ArrayNote.find!(note.id)
        stored.title.should eq("left")
        stored.tags.should eq(["a", "b"])
      end
    end
  end

  describe "converter-backed mutable columns" do
    it "detects an in-place edit of a Hash column when the model opts in" do
      note = W6DocNote.create!(title: "t", options: {"a" => "1"})
      loaded = W6DocNote.find!(note.id)
      loaded.changed?.should be_false

      loaded.options.not_nil!["b"] = "2"
      loaded.changed?.should be_true
      loaded.options_was.should eq({"a" => "1"})
      loaded.options_change.should eq({ {"a" => "1"}, {"a" => "1", "b" => "2"} })

      loaded.save!
      W6DocNote.find!(note.id).options.should eq({"a" => "1", "b" => "2"})
      loaded.changed?.should be_false
    end

    it "is clean again when the edit is undone" do
      note = W6DocNote.create!(title: "t", options: {"a" => "1"})
      loaded = W6DocNote.find!(note.id)
      loaded.options.not_nil!["b"] = "2"
      loaded.changed?.should be_true
      loaded.options.not_nil!.delete("b")
      loaded.changed?.should be_false
    end

    it "detects an in-place edit of a JSON document" do
      note = W6DocNote.create!(title: "t", payload: JSON.parse(%({"k": "v"})))
      loaded = W6DocNote.find!(note.id)
      loaded.changed?.should be_false

      loaded.payload.not_nil!.as_h["k"] = JSON::Any.new("changed")
      loaded.changed?.should be_true
      loaded.save!
      W6DocNote.find!(note.id).payload.not_nil!["k"].as_s.should eq("changed")
    end

    it "does not watch a converter column on a model that did not opt in" do
      note = W6DocPlain.create!(options: {"a" => "1"})
      loaded = W6DocPlain.find!(note.id)
      loaded.options.not_nil!["b"] = "2"
      loaded.changed?.should be_false
      W6DocPlain.mutation_detected_attributes.should be_empty
    end
  end

  describe "attribute_will_change! on a serialized column" do
    it "re-serializes the raw column at once" do
      record = F01PlainPrefs.new
      record.prefs = F01Settings.new
      record.save!

      loaded = F01PlainPrefs.find!(record.id)
      loaded.prefs.not_nil!.items << "x"
      loaded.changed?.should be_false

      loaded.attribute_will_change!(:prefs)
      loaded.changed?.should be_true
      change = loaded.changes_to_save["_serialized_prefs"]
      change[1].as(String).should contain("\"x\"")
      change[0].as(String).should_not contain("\"x\"")

      loaded.save!
      F01PlainPrefs.find!(record.id).prefs.not_nil!.items.should eq(["x"])
    end
  end
end
