require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class AcOwner < Grant::Base
    connection {{ adapter_literal }}
    table ac_owners
    column id : Int64, primary: true
    column name : String?

    getter log = [] of String
    property allow_add : Bool = true
    property allow_remove : Bool = true

    has_many :ac_symbols, class_name: AcItem, foreign_key: :ac_owner_id,
      before_add: :check_add, after_add: :note_added,
      before_remove: :check_remove, after_remove: :note_removed

    has_many :ac_procs, class_name: AcItem, foreign_key: :ac_owner_id,
      before_add: ->(owner : AcOwner, item : AcItem) { owner.log << "proc before_add"; owner.allow_add },
      after_add: ->(owner : AcOwner, item : AcItem) { owner.log << "proc after_add" },
      after_remove: [:note_removed, ->(owner : AcOwner, item : AcItem) { owner.log << "proc after_remove" }]

    has_many :ac_plain, class_name: AcItem, foreign_key: :ac_owner_id

    private def check_add(item : AcItem)
      log << "before_add"
      allow_add
    end

    private def note_added(item : AcItem)
      log << "after_add"
    end

    private def check_remove(item : AcItem)
      log << "before_remove"
      allow_remove
    end

    private def note_removed(item : AcItem)
      log << "after_remove"
    end
  end

  class AcItem < Grant::Base
    connection {{ adapter_literal }}
    table ac_items
    column id : Int64, primary: true
    column note : String?
    column ac_owner_id : Int64?
  end
{% end %}

describe "association callbacks" do
  before_all do
    AcOwner.migrator.drop_and_create
    AcItem.migrator.drop_and_create
  end

  before_each do
    AcItem.clear
    AcOwner.clear
  end

  describe "method name hooks" do
    it "runs before_add then after_add around <<" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(note: "n")

      owner.ac_symbols << item

      owner.log.should eq(["before_add", "after_add"])
      AcItem.find!(item.id).ac_owner_id.should eq(owner.id)
    end

    it "runs the add hooks for build and create" do
      owner = AcOwner.create!(name: "o")

      owner.ac_symbols.build(note: "b")
      owner.ac_symbols.create(note: "c")

      owner.log.should eq(["before_add", "after_add", "before_add", "after_add"])
    end

    it "runs the remove hooks around delete" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(ac_owner_id: owner.id, note: "n")

      owner.ac_symbols.delete(item)

      owner.log.should eq(["before_remove", "after_remove"])
      AcItem.find!(item.id).ac_owner_id.should be_nil
    end

    it "runs the remove hooks around destroy" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(ac_owner_id: owner.id, note: "n")

      owner.ac_symbols.destroy(item)

      owner.log.should eq(["before_remove", "after_remove"])
      AcItem.find(item.id).should be_nil
    end

    it "fires per record for a bulk add and remove through the ids writer" do
      owner = AcOwner.create!(name: "o")
      first = AcItem.create!(note: "n")
      second = AcItem.create!(note: "n")

      owner.ac_symbol_ids = [first.id, second.id]
      owner.log.should eq(["before_add", "before_add", "after_add", "after_add"])

      owner.log.clear
      owner.ac_symbol_ids = [] of Int64
      owner.log.should eq(["before_remove", "before_remove", "after_remove", "after_remove"])
      AcItem.where(ac_owner_id: owner.id).count.should eq(0)
    end

    it "does not run remove hooks for delete_all, as in ActiveRecord" do
      owner = AcOwner.create!(name: "o")
      AcItem.create!(ac_owner_id: owner.id, note: "n")

      owner.ac_symbols.delete_all

      owner.log.should be_empty
    end
  end

  describe "before_ hooks that veto" do
    it "skips the append when before_add returns false" do
      owner = AcOwner.create!(name: "o")
      owner.allow_add = false
      item = AcItem.create!(note: "n")

      owner.ac_symbols << item

      owner.log.should eq(["before_add"])
      AcItem.find!(item.id).ac_owner_id.should be_nil
      owner.ac_symbols.to_a.should be_empty
    end

    it "does not build into the collection when before_add returns false" do
      owner = AcOwner.create!(name: "o")
      owner.allow_add = false
      collection = owner.ac_symbols
      collection.load_target

      collection.build(note: "b")

      collection.to_a.should be_empty
      owner.log.should eq(["before_add"])
    end

    it "does not save on create when before_add returns false" do
      owner = AcOwner.create!(name: "o")
      owner.allow_add = false

      item = owner.ac_symbols.create(note: "c")

      item.persisted?.should be_false
      AcItem.count.should eq(0)
    end

    it "keeps the record when before_remove returns false" do
      owner = AcOwner.create!(name: "o")
      owner.allow_remove = false
      item = AcItem.create!(ac_owner_id: owner.id, note: "n")

      owner.ac_symbols.delete(item).should be_empty
      owner.ac_symbols.destroy(item).should be_empty

      AcItem.find!(item.id).ac_owner_id.should eq(owner.id)
      owner.log.should eq(["before_remove", "before_remove"])
    end

    it "stops the whole append when one of several records is vetoed" do
      owner = AcOwner.create!(name: "o")
      owner.allow_add = false
      first = AcItem.create!(note: "n")
      second = AcItem.create!(note: "n")

      owner.ac_symbols.append(first, second)

      AcItem.where(ac_owner_id: owner.id).count.should eq(0)
    end
  end

  describe "proc hooks" do
    it "passes the owner and the record to a typed proc" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(note: "n")

      owner.ac_procs << item

      owner.log.should eq(["proc before_add", "proc after_add"])
    end

    it "vetoes when a proc returns false" do
      owner = AcOwner.create!(name: "o")
      owner.allow_add = false
      item = AcItem.create!(note: "n")

      owner.ac_procs << item

      AcItem.find!(item.id).ac_owner_id.should be_nil
    end

    it "accepts an array mixing method names and procs" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(ac_owner_id: owner.id, note: "n")

      owner.ac_procs.delete(item)

      owner.log.should eq(["after_remove", "proc after_remove"])
    end
  end

  describe "without hooks" do
    it "behaves like a plain collection" do
      owner = AcOwner.create!(name: "o")
      item = AcItem.create!(note: "n")

      owner.ac_plain << item
      owner.ac_plain.delete(item)

      owner.log.should be_empty
      AcItem.find!(item.id).ac_owner_id.should be_nil
    end
  end
end
