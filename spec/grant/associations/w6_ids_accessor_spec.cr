require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6iOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6i_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6i_items, class_name: W6iItem, foreign_key: :w6i_owner_id
    has_many :w6i_images, as: :imageable, class_name: W6iImage
    has_many :w6i_hooked, class_name: W6iItem, foreign_key: :w6i_owner_id,
      before_add: :hook_before_add, after_add: :hook_after_add,
      before_remove: :hook_before_remove, after_remove: :hook_after_remove

    getter log = [] of String

    private def hook_before_add(item : W6iItem)
      log << "before_add"
      true
    end

    private def hook_after_add(item : W6iItem)
      log << "after_add"
    end

    private def hook_before_remove(item : W6iItem)
      log << "before_remove"
      true
    end

    private def hook_after_remove(item : W6iItem)
      log << "after_remove"
    end
  end

  class W6iOther < Grant::Base
    connection {{ adapter_literal }}
    table w6i_others
    column id : Int64, primary: true
    column name : String?
    has_many :w6i_images, as: :imageable, class_name: W6iImage
  end

  class W6iItem < Grant::Base
    connection {{ adapter_literal }}
    table w6i_items
    column id : Int64, primary: true
    column label : String?
    column w6i_owner_id : Int64?
    column touched : Int32 = 0
    timestamps

    before_save :count_save

    private def count_save
      self.touched = touched + 1
    end

    validate "label must not be forbidden" do |item|
      item.label != "forbidden"
    end
  end

  class W6iImage < Grant::Base
    connection {{ adapter_literal }}
    table w6i_images
    column id : Int64, primary: true
    column url : String?
    belongs_to :imageable, polymorphic: true, optional: true
  end
{% end %}

describe "has_many ids accessor" do
  before_all do
    W6iOwner.migrator.drop_and_create
    W6iOther.migrator.drop_and_create
    W6iItem.migrator.drop_and_create
    W6iImage.migrator.drop_and_create
  end

  before_each do
    W6iImage.clear
    W6iItem.clear
    W6iOther.clear
    W6iOwner.clear
  end

  describe "typed reader" do
    it "returns the keys as the key column type" do
      owner = W6iOwner.create!(name: "o")
      item = W6iItem.create!(label: "a", w6i_owner_id: owner.id)

      ids = owner.w6i_item_ids

      typeof(ids).should eq(Array(Int64))
      ids.should eq([item.id])
    end
  end

  describe "writer" do
    it "casts numeric strings to the key type and ignores blanks" do
      owner = W6iOwner.create!(name: "o")
      a = W6iItem.create!(label: "a")
      b = W6iItem.create!(label: "b")

      owner.w6i_item_ids = [a.id.to_s, "", nil, b.id.to_s, a.id]

      owner.w6i_item_ids.sort!.should eq([a.id, b.id].sort_by(&.not_nil!))
      W6iItem.find!(a.id).w6i_owner_id.should eq(owner.id)
    end

    it "saves each added record: validations, callbacks and the updated_at touch run" do
      owner = W6iOwner.create!(name: "o")
      item = W6iItem.create!(label: "a")
      before_touched = item.touched
      before_update = item.updated_at

      sleep 5.milliseconds
      owner.w6i_item_ids = [item.id]

      reloaded = W6iItem.find!(item.id)
      reloaded.w6i_owner_id.should eq(owner.id)
      reloaded.touched.should eq(before_touched + 1)
      (reloaded.updated_at.not_nil! > before_update.not_nil!).should be_true
    end

    it "fails and changes nothing when an added record is invalid" do
      owner = W6iOwner.create!(name: "o")
      keep = W6iItem.create!(label: "keep", w6i_owner_id: owner.id)
      bad = W6iItem.create!(label: "ok")
      bad.update_columns(label: "forbidden")

      expect_raises(Grant::RecordInvalid) { owner.w6i_item_ids = [bad.id] }

      W6iItem.find!(keep.id).w6i_owner_id.should eq(owner.id)
      W6iItem.find!(bad.id).w6i_owner_id.should be_nil
    end

    it "runs the association hooks" do
      owner = W6iOwner.create!(name: "o")
      old = W6iItem.create!(label: "old", w6i_owner_id: owner.id)
      added = W6iItem.create!(label: "new")
      owner.log.clear

      owner.w6i_hooked_ids = [added.id]

      owner.log.should eq(["before_remove", "after_remove", "before_add", "after_add"])
      W6iItem.find!(old.id).w6i_owner_id.should be_nil
      W6iItem.find!(added.id).w6i_owner_id.should eq(owner.id)
    end

    it "removes with one UPDATE and does not load the removed records" do
      owner = W6iOwner.create!(name: "o")
      keep = W6iItem.create!(label: "keep", w6i_owner_id: owner.id)
      2.times { |i| W6iItem.create!(label: "drop#{i}", w6i_owner_id: owner.id) }

      statements = StatementRecorder.statements { owner.w6i_item_ids = [keep.id] }

      StatementRecorder.count(statements, "UPDATE", "w6i_items").should eq(1)
      W6iItem.where(w6i_owner_id: owner.id).count.should eq(1)
    end
  end

  describe "as: polymorphic collections" do
    it "generates the reader and writer" do
      owner = W6iOwner.create!(name: "o")
      other = W6iOther.create!(name: "x")
      mine = W6iImage.create!(url: "mine", imageable_id: owner.id, imageable_type: "W6iOwner")
      theirs = W6iImage.create!(url: "theirs", imageable_id: other.id, imageable_type: "W6iOther")

      owner.w6i_image_ids.should eq([mine.id])
      other.w6i_image_ids.should eq([theirs.id])
      typeof(owner.w6i_image_ids).should eq(Array(Int64))
    end

    it "writes the key and the type and removes the others" do
      owner = W6iOwner.create!(name: "o")
      other = W6iOther.create!(name: "x")
      old = W6iImage.create!(url: "old", imageable_id: owner.id, imageable_type: "W6iOwner")
      free = W6iImage.create!(url: "free")
      foreign = W6iImage.create!(url: "foreign", imageable_id: other.id, imageable_type: "W6iOther")

      owner.w6i_image_ids = [free.id, foreign.id]

      moved = W6iImage.find!(free.id)
      moved.imageable_id.should eq(owner.id)
      moved.imageable_type.should eq("W6iOwner")
      W6iImage.find!(foreign.id).imageable_type.should eq("W6iOwner")
      W6iImage.find!(old.id).imageable_id.should be_nil
      owner.w6i_image_ids.sort!.should eq([free.id, foreign.id].sort_by(&.not_nil!))
      other.w6i_image_ids.should be_empty
    end

    it "raises RecordNotFound for a missing key and OwnerNotSaved for an unsaved owner" do
      owner = W6iOwner.create!(name: "o")

      expect_raises(Grant::RecordNotFound) { owner.w6i_image_ids = [999_999_i64] }
      image = W6iImage.create!(url: "free")
      expect_raises(Grant::Associations::OwnerNotSaved) { W6iOwner.new(name: "n").w6i_image_ids = [image.id] }
    end
  end
end
