require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CiOwner < Grant::Base
    connection {{ adapter_literal }}
    table ci_owners
    column id : Int64, primary: true
    column name : String?
    has_many :ci_items, class_name: CiItem, foreign_key: :ci_owner_id
    has_many :ci_people, class_name: CiPerson, foreign_key: :ci_owner_id, singular: :ci_person
  end

  class CiItem < Grant::Base
    connection {{ adapter_literal }}
    table ci_items
    column id : Int64, primary: true
    column label : String?
    column ci_owner_id : Int64?
    belongs_to :ci_owner, class_name: CiOwner, foreign_key: :ci_owner_id, optional: true
  end

  class CiPerson < Grant::Base
    connection {{ adapter_literal }}
    table ci_people
    column id : Int64, primary: true
    column note : String?
    column ci_owner_id : Int64?
  end
{% end %}

private def sorted(ids) : Array(String)
  ids.map(&.to_s).sort!
end

describe "collection ids reader and writer" do
  before_all do
    CiOwner.migrator.drop_and_create
    CiItem.migrator.drop_and_create
    CiPerson.migrator.drop_and_create
  end

  before_each do
    CiItem.clear
    CiPerson.clear
    CiOwner.clear
  end

  describe "ci_item_ids" do
    it "plucks only the key column when the collection is not loaded" do
      owner = CiOwner.create!(name: "o")
      items = Array.new(3) { |i| CiItem.create!(label: "l#{i}", ci_owner_id: owner.id) }

      ids = [] of Grant::Columns::Type
      statements = StatementRecorder.statements { ids = owner.ci_item_ids }

      sorted(ids).should eq(sorted(items.map(&.id)))
      selects = statements.select(&.upcase.starts_with?("SELECT"))
      selects.size.should eq(1)
      selects.first.should_not contain("label")
    end

    it "reads a loaded collection without a query" do
      owner = CiOwner.create!(name: "o")
      item = CiItem.create!(label: "a", ci_owner_id: owner.id)
      collection = owner.ci_items
      collection.load_target

      statements = StatementRecorder.statements { collection.ids.should eq([item.id]) }

      statements.should be_empty
    end
  end

  describe "ci_item_ids=" do
    it "validates every id with a single IN query" do
      owner = CiOwner.create!(name: "o")
      a = CiItem.create!(label: "a")
      b = CiItem.create!(label: "b")

      statements = StatementRecorder.statements { owner.ci_item_ids = [a.id, b.id] }

      lookups = statements.select { |sql| sql.upcase.starts_with?("SELECT") && sql.upcase.includes?(" IN ") }
      lookups.size.should eq(1)
      sorted(owner.ci_item_ids).should eq(sorted([a.id, b.id]))
    end

    it "raises RecordNotFound for an id that does not exist and changes nothing" do
      owner = CiOwner.create!(name: "o")
      a = CiItem.create!(label: "a", ci_owner_id: owner.id)
      b = CiItem.create!(label: "b")

      expect_raises(Grant::RecordNotFound, /999999/) do
        owner.ci_item_ids = [b.id, 999_999_i64]
      end

      CiItem.find!(a.id).ci_owner_id.should eq(owner.id)
      CiItem.find!(b.id).ci_owner_id.should be_nil
    end

    it "applies the difference with one UPDATE per direction" do
      owner = CiOwner.create!(name: "o")
      keep = CiItem.create!(label: "keep", ci_owner_id: owner.id)
      drop = CiItem.create!(label: "drop", ci_owner_id: owner.id)
      add = CiItem.create!(label: "add")

      statements = StatementRecorder.statements { owner.ci_item_ids = [keep.id, add.id] }

      StatementRecorder.count(statements, "UPDATE", "ci_items").should eq(2)
      StatementRecorder.count(statements, "BEGIN").should be <= 1
      CiItem.find!(keep.id).ci_owner_id.should eq(owner.id)
      CiItem.find!(add.id).ci_owner_id.should eq(owner.id)
      CiItem.find!(drop.id).ci_owner_id.should be_nil
    end

    it "does not touch the database when the set is unchanged" do
      owner = CiOwner.create!(name: "o")
      item = CiItem.create!(label: "a", ci_owner_id: owner.id)

      statements = StatementRecorder.statements { owner.ci_item_ids = [item.id] }

      StatementRecorder.count(statements, "UPDATE").should eq(0)
    end

    it "ignores blank and duplicate ids" do
      owner = CiOwner.create!(name: "o")
      item = CiItem.create!(label: "a")

      owner.ci_item_ids = [nil, "", item.id, item.id]

      owner.ci_item_ids.should eq([item.id])
    end

    it "moves a record away from its previous owner" do
      first = CiOwner.create!(name: "1")
      second = CiOwner.create!(name: "2")
      item = CiItem.create!(label: "a", ci_owner_id: first.id)

      second.ci_item_ids = [item.id]

      first.ci_item_ids.should be_empty
      second.ci_item_ids.should eq([item.id])
    end

    it "empties the collection with an empty list" do
      owner = CiOwner.create!(name: "o")
      CiItem.create!(label: "a", ci_owner_id: owner.id)

      owner.ci_item_ids = [] of Int64

      owner.ci_item_ids.should be_empty
      CiItem.count.should eq(1)
    end

    it "links the records when the owner is saved for the first time" do
      item = CiItem.create!(label: "a")
      owner = CiOwner.new(name: "new")

      owner.ci_item_ids = [item.id]
      owner.save.should be_true

      CiItem.find!(item.id).ci_owner_id.should eq(owner.id)
    end

    it "uses the singular: option for irregular plurals" do
      owner = CiOwner.create!(name: "o")
      person = CiPerson.create!(note: "n")

      owner.ci_person_ids = [person.id]

      owner.ci_person_ids.should eq([person.id])
    end
  end
end
