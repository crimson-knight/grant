require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6VbEntry < Grant::Base
    connection {{ adapter_literal }}
    table w6_vb_entries

    column id : Int64, primary: true
    column title : String?
    column stage : String?
    column halt : Bool?

    validates_presence_of :title
    validates_presence_of :stage, on: :publish
    validates_length_of :title, maximum: 10

    before_save { abort! if halt }
  end
{% end %}

describe "Grant::RecordInvalid from validate!, save!, create! and update!" do
  before_all do
    W6VbEntry.migrator.drop_and_create
  end

  before_each do
    W6VbEntry.clear
  end

  describe "validate!" do
    it "returns the record when it is valid, so calls chain" do
      entry = W6VbEntry.new(title: "Hi")
      entry.validate!.should be(entry)
      entry.validate!.title.should eq("Hi")
    end

    it "raises Grant::RecordInvalid whose message lists the full messages" do
      entry = W6VbEntry.new
      ex = expect_raises(Grant::RecordInvalid, "Validation failed: Title can't be blank") { entry.validate! }
      ex.record.should be(entry)
      ex.message.should eq("Validation failed: Title can't be blank")
    end

    it "joins several messages with a comma" do
      entry = W6VbEntry.new(title: "a" * 11)
      expect_raises(Grant::RecordInvalid, "Validation failed: Stage can't be blank, Title is too long (maximum is 10 characters)") do
        entry.validate!(:publish)
      end
    end

    it "takes a context, positional or keyword, and an Array of them" do
      entry = W6VbEntry.new(title: "Hi")
      entry.validate!.should be(entry)
      expect_raises(Grant::RecordInvalid, /Stage can't be blank/) { entry.validate!(:publish) }
      expect_raises(Grant::RecordInvalid, /Stage can't be blank/) { entry.validate!(context: :publish) }
      expect_raises(Grant::RecordInvalid, /Stage can't be blank/) { entry.validate!([:create, :publish]) }
      entry.stage = "live"
      entry.validate!(:publish).should be(entry)
    end

    it "does not persist anything" do
      expect_raises(Grant::RecordInvalid) { W6VbEntry.new.validate! }
      W6VbEntry.count.should eq(0)
    end

    it "is rescuable as Grant::RecordNotSaved and Grant::ErrorBase" do
      expect_raises(Grant::RecordNotSaved) { W6VbEntry.new.validate! }
      expect_raises(Grant::ErrorBase) { W6VbEntry.new.validate! }
    end

    it "leaves the errors on the record for the rescue block" do
      entry = W6VbEntry.new
      begin
        entry.validate!
      rescue ex : Grant::RecordInvalid
        ex.record.errors.details["title"].should eq([{:error => :blank}])
        ex.record.errors.to_json.should eq(%({"title":["can't be blank"]}))
      end
    end
  end

  describe "the persistence bang methods" do
    it "save! raises RecordInvalid for a new and for a persisted record" do
      expect_raises(Grant::RecordInvalid, "Validation failed: Title can't be blank") { W6VbEntry.new.save! }
      entry = W6VbEntry.create!(title: "ok")
      entry.title = nil
      expect_raises(Grant::RecordInvalid, "Validation failed: Title can't be blank") { entry.save! }
      W6VbEntry.find!(entry.id).title.should eq("ok")
    end

    it "create! raises RecordInvalid and stores nothing" do
      ex = expect_raises(Grant::RecordInvalid, "Validation failed: Title can't be blank") { W6VbEntry.create!(stage: "x") }
      ex.record.should be_a(W6VbEntry)
      W6VbEntry.count.should eq(0)
    end

    it "update! raises RecordInvalid and keeps the stored row" do
      entry = W6VbEntry.create!(title: "ok")
      expect_raises(Grant::RecordInvalid, /Title is too long/) { entry.update!(title: "a" * 11) }
      W6VbEntry.find!(entry.id).title.should eq("ok")
    end

    it "save! accepts a context" do
      entry = W6VbEntry.new(title: "ok")
      expect_raises(Grant::RecordInvalid, /Stage can't be blank/) { entry.save!(context: :publish) }
      entry.stage = "live"
      entry.save!(context: :publish).should be_true
    end

    it "raises RecordNotSaved, not RecordInvalid, with a safe message when a callback aborts" do
      entry = W6VbEntry.new(title: "ok", halt: true)
      ex = expect_raises(Grant::RecordNotSaved) { entry.save! }
      ex.should_not be_a(Grant::RecordInvalid)
      ex.message.to_s.should contain("Could not process W6VbEntry")
      ex.model.should be(entry)
      W6VbEntry.count.should eq(0)
    end
  end
end
