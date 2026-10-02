require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class MfdOwner < Grant::Base
    connection {{ adapter_literal }}
    table mfd_owners
    column id : Int64, primary: true
    column name : String?

    has_many :mfd_items, class_name: MfdItem, foreign_key: :mfd_owner_id, autosave: true
    has_many :mfd_plain_items, class_name: MfdPlainItem, foreign_key: :mfd_owner_id
    has_one :mfd_detail, class_name: MfdDetail, foreign_key: :mfd_owner_id, autosave: true
  end

  class MfdItem < Grant::Base
    connection {{ adapter_literal }}
    table mfd_items
    column id : Int64, primary: true
    column mfd_owner_id : Int64?
    column label : String?
    validates_presence_of :label
  end

  class MfdPlainItem < Grant::Base
    connection {{ adapter_literal }}
    table mfd_plain_items
    column id : Int64, primary: true
    column mfd_owner_id : Int64?
    column label : String?
  end

  class MfdDetail < Grant::Base
    connection {{ adapter_literal }}
    table mfd_details
    column id : Int64, primary: true
    column mfd_owner_id : Int64?
    column note : String?
  end

  class MfdParent < Grant::Base
    connection {{ adapter_literal }}
    table mfd_parents
    column id : Int64, primary: true
    column name : String?
  end

  class MfdChild < Grant::Base
    connection {{ adapter_literal }}
    table mfd_children
    column id : Int64, primary: true
    column mfd_parent_id : Int64?
    belongs_to :mfd_parent, class_name: MfdParent, foreign_key: mfd_parent_id : Int64?, autosave: true, optional: true
  end
{% end %}

describe "mark_for_destruction" do
  before_all do
    MfdOwner.migrator.drop_and_create
    MfdItem.migrator.drop_and_create
    MfdPlainItem.migrator.drop_and_create
    MfdDetail.migrator.drop_and_create
    MfdParent.migrator.drop_and_create
    MfdChild.migrator.drop_and_create
  end

  before_each do
    MfdItem.clear
    MfdPlainItem.clear
    MfdDetail.clear
    MfdChild.clear
    MfdOwner.clear
    MfdParent.clear
  end

  it "flags a record and can be reset" do
    item = MfdItem.new(label: "a")
    item.marked_for_destruction?.should be_false

    item.mark_for_destruction
    item.marked_for_destruction?.should be_true

    item.reset_destruction
    item.marked_for_destruction?.should be_false
  end

  it "counts as a change for autosave" do
    item = MfdItem.create!(label: "a")
    item.changed_for_autosave?.should be_false

    item.mark_for_destruction
    item.changed_for_autosave?.should be_true
  end

  it "is cleared by reload" do
    item = MfdItem.create!(label: "a")
    item.mark_for_destruction

    item.reload
    item.marked_for_destruction?.should be_false
  end

  it "reload drops records built on the owner but not saved" do
    owner = MfdOwner.create!(name: "o")
    owner.mfd_plain_items.build(label: "staged")

    owner.reload
    owner.save.should be_true
    MfdPlainItem.where(mfd_owner_id: owner.id).count.should eq(0)
  end

  describe "has_many autosave: true" do
    it "destroys the marked children when the owner is saved and drops them from the target" do
      owner = MfdOwner.create!(name: "o")
      keep = MfdItem.create!(label: "keep", mfd_owner_id: owner.id)
      drop = MfdItem.create!(label: "drop", mfd_owner_id: owner.id)

      owner = MfdOwner.find!(owner.id)
      items = owner.mfd_items.load_target
      items.find { |item| item.id == drop.id }.not_nil!.mark_for_destruction

      # Nothing happens before the owner is saved.
      MfdItem.count.should eq(2)

      owner.save.should be_true

      MfdItem.find(drop.id).should be_nil
      MfdItem.find(keep.id).should_not be_nil
      owner.mfd_items.to_a.map(&.id).should eq([keep.id])
    end

    it "does not validate a child that is about to be destroyed" do
      owner = MfdOwner.create!(name: "o")
      item = MfdItem.create!(label: "ok", mfd_owner_id: owner.id)

      owner = MfdOwner.find!(owner.id)
      loaded = owner.mfd_items.load_target.first
      loaded.label = ""
      loaded.mark_for_destruction

      owner.save.should be_true
      MfdItem.find(item.id).should be_nil
    end

    it "never saves a new child that is marked" do
      owner = MfdOwner.create!(name: "o")
      built = owner.mfd_items.build(label: "unsaved")
      built.mark_for_destruction

      owner.save.should be_true
      MfdItem.count.should eq(0)
    end
  end

  describe "without autosave: true" do
    it "leaves marked children in place" do
      owner = MfdOwner.create!(name: "o")
      item = MfdPlainItem.create!(label: "x", mfd_owner_id: owner.id)

      owner = MfdOwner.find!(owner.id)
      owner.mfd_plain_items.load_target.first.mark_for_destruction

      owner.save.should be_true
      MfdPlainItem.find(item.id).should_not be_nil
    end
  end

  describe "has_one autosave: true" do
    it "destroys the marked child" do
      owner = MfdOwner.create!(name: "o")
      detail = MfdDetail.create!(note: "n", mfd_owner_id: owner.id)

      owner = MfdOwner.find!(owner.id)
      owner.mfd_detail.not_nil!.mark_for_destruction
      owner.save.should be_true

      MfdDetail.find(detail.id).should be_nil
    end
  end

  describe "belongs_to autosave: true" do
    it "destroys the marked parent and clears the key" do
      parent = MfdParent.create!(name: "p")
      child = MfdChild.create!(mfd_parent_id: parent.id)

      child = MfdChild.find!(child.id)
      child.mfd_parent = MfdParent.find!(parent.id)
      child.mfd_parent.not_nil!.mark_for_destruction
      child.save.should be_true

      MfdParent.find(parent.id).should be_nil
      MfdChild.find!(child.id).mfd_parent_id.should be_nil
    end
  end
end
