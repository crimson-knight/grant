require "../../spec_helper"
require "../../support/association_query_counter"

describe "Grant::DelegatedType" do
  before_all do
    DtxEntry.migrator.drop_and_create
    DtxMessage.migrator.drop_and_create
    DtxComment.migrator.drop_and_create
    DtxAdminNote.migrator.drop_and_create
    DtxDeleteHolder.migrator.drop_and_create
    DtxPlainHolder.migrator.drop_and_create
  end

  before_each do
    DtxEntry.clear
    DtxMessage.clear
    DtxComment.clear
    DtxAdminNote.clear
  end

  describe "predicates and readers" do
    it "answers from the stored type string without a query" do
      message = DtxMessage.create!(body: "Hi")
      entry = DtxEntry.new(title: "e")
      entry.entryable = message

      queries = AssociationQueryCounter.selects do
        entry.dtx_message?.should be_true
        entry.dtx_comment?.should be_false
        entry.dtx_message_id.should eq(message.id)
        entry.dtx_comment_id.should be_nil
        entry.dtx_comment.should be_nil
        entry.entryable_name.should eq("dtx_message")
        entry.entryable_class.should eq(DtxMessage)
      end
      queries.should eq(0)
    end

    it "loads the matching reader once and nil for the other types" do
      message = DtxMessage.create!(body: "Hi")
      entry = DtxEntry.create!(title: "e", entryable: message)
      found = DtxEntry.find!(entry.id)
      found.dtx_message.not_nil!.body.should eq("Hi")
      found.dtx_comment.should be_nil
      found.dtx_message?.should be_true
    end

    it "handles an unset type" do
      entry = DtxEntry.new(title: "e")
      entry.dtx_message?.should be_false
      entry.dtx_message.should be_nil
      entry.entryable_name.should be_nil
      entry.entryable_class.should be_nil
    end

    it "raises for a stored type outside the list" do
      entry = DtxEntry.new(title: "e")
      entry.entryable_type = "Bogus"
      expect_raises(Grant::DelegatedType::UnknownTypeError, /Bogus/) { entry.entryable_class }
      entry.dtx_message?.should be_false
    end

    it "names namespaced-free multi word types and pluralizes scopes" do
      DtxEntry.create!(title: "a", entryable: DtxMessage.create!(body: "m"))
      DtxEntry.create!(title: "b", entryable: DtxComment.create!(content: "c"))
      DtxEntry.dtx_messages.count.should eq(1)
      DtxEntry.dtx_comments.count.should eq(1)
      DtxEntry.dtx_admin_notes.count.should eq(0)
    end
  end

  describe "build_entryable" do
    it "builds and assigns a target of the given class" do
      entry = DtxEntry.new(title: "e")
      built = entry.build_entryable(DtxComment, content: "Built")
      built.should be_a(DtxComment)
      entry.dtx_comment?.should be_true
      entry.entryable_type.should eq("DtxComment")
      entry.dtx_comment.should be(built)
    end

    it "builds a target of the currently stored type" do
      entry = DtxEntry.new(title: "e")
      entry.entryable_type = "DtxMessage"
      built = entry.build_entryable(body: "Typed")
      built.should be_a(DtxMessage)
      entry.dtx_message.not_nil!.body.should eq("Typed")
    end

    it "raises when no type is set" do
      entry = DtxEntry.new(title: "e")
      expect_raises(Grant::DelegatedType::TypeNotSetError) { entry.build_entryable(body: "x") }
    end

    it "persists through autosave-free manual save" do
      entry = DtxEntry.new(title: "e")
      target = entry.build_entryable(DtxMessage, body: "Saved")
      target.save!
      entry.entryable = target
      entry.save!
      DtxEntry.find!(entry.id).dtx_message.not_nil!.body.should eq("Saved")
    end
  end

  describe "exhaustive case" do
    it "dispatches over the closed type list" do
      entries = [
        DtxEntry.create!(title: "a", entryable: DtxMessage.create!(body: "m")),
        DtxEntry.create!(title: "b", entryable: DtxComment.create!(content: "c")),
        DtxEntry.create!(title: "c", entryable: DtxAdminNote.create!(note: "n")),
      ]
      labels = entries.map do |entry|
        case klass = entry.entryable_class
        when DtxMessage.class   then "message"
        when DtxComment.class   then "comment"
        when DtxAdminNote.class then "note"
        else                         "none"
        end
      end
      labels.should eq(["message", "comment", "note"])
    end
  end

  describe "preload" do
    it "groups by type with one IN query per type" do
      3.times { |i| DtxEntry.create!(title: "m#{i}", entryable: DtxMessage.create!(body: "m#{i}")) }
      2.times { |i| DtxEntry.create!(title: "c#{i}", entryable: DtxComment.create!(content: "c#{i}")) }

      entries = [] of DtxEntry
      queries = AssociationQueryCounter.selects do
        entries = DtxEntry.includes(:entryable).order(:id).select.to_a
        entries.each do |entry|
          entry.dtx_message.try(&.body)
          entry.dtx_comment.try(&.content)
        end
      end
      # one query for entries, one per stored type
      queries.should eq(3)
      entries.count(&.dtx_message?).should eq(3)
      entries.count(&.dtx_comment?).should eq(2)
      entries.first.dtx_message.not_nil!.body.should eq("m0")
    end
  end

  describe "dependent" do
    it "destroys the target with dependent: :destroy" do
      message = DtxMessage.create!(body: "gone")
      entry = DtxEntry.create!(title: "e", entryable: message)
      entry.destroy
      DtxMessage.find(message.id).should be_nil
    end

    it "deletes the target with dependent: :delete" do
      note = DtxAdminNote.create!(note: "gone")
      holder = DtxDeleteHolder.create!(entryable: note)
      holder.destroy
      DtxAdminNote.find(note.id).should be_nil
    end

    it "leaves the target without dependent" do
      comment = DtxComment.create!(content: "stay")
      plain = DtxPlainHolder.create!(entryable: comment)
      plain.destroy
      DtxComment.find(comment.id).should_not be_nil
    end
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class DtxMessage < Grant::Base
    connection {{ adapter_literal }}
    table dtx_messages
    column id : Int64, primary: true
    column body : String
  end

  class DtxComment < Grant::Base
    connection {{ adapter_literal }}
    table dtx_comments
    column id : Int64, primary: true
    column content : String
  end

  class DtxAdminNote < Grant::Base
    connection {{ adapter_literal }}
    table dtx_admin_notes
    column id : Int64, primary: true
    column note : String
  end

  class DtxEntry < Grant::Base
    connection {{ adapter_literal }}
    table dtx_entries
    column id : Int64, primary: true
    column title : String
    delegated_type :entryable, types: {DtxMessage, DtxComment, DtxAdminNote}, dependent: :destroy
  end

  class DtxDeleteHolder < Grant::Base
    connection {{ adapter_literal }}
    table dtx_delete_holders
    column id : Int64, primary: true
    delegated_type :entryable, types: {DtxAdminNote}, dependent: :delete
  end

  class DtxPlainHolder < Grant::Base
    connection {{ adapter_literal }}
    table dtx_plain_holders
    column id : Int64, primary: true
    delegated_type :entryable, types: {DtxComment}
  end
{% end %}
