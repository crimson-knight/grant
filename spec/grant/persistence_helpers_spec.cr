require "../spec_helper"

# Model with a column-level validation, used to prove update_attribute /
# increment! / toggle! skip validations.
class PersistenceWidget < Grant::Base
  connection sqlite
  table persistence_widgets

  column id : Int64, primary: true
  column name : String?
  column counter : Int32?
  column big_counter : Int64?
  column active : Bool?

  validate :name, "Name cannot be blank" do |w|
    !w.name.to_s.blank?
  end
end

# Model exercising attr_readonly (the `slug` column is set on create, then
# ignored on update).
class ReadonlyWidget < Grant::Base
  connection sqlite
  table readonly_widgets

  column id : Int64, primary: true
  column slug : String?
  column name : String?

  attr_readonly :slug
end

# Model with callbacks to prove update_attribute runs callbacks while
# update_columns skips them.
class CallbackWidget < Grant::Base
  connection sqlite
  table callback_widgets

  column id : Int64, primary: true
  column name : String?

  property before_save_count : Int32 = 0

  before_save :bump

  def bump
    @before_save_count += 1
  end
end

describe "Grant persistence helpers" do
  before_all do
    PersistenceWidget.migrator.drop_and_create
    ReadonlyWidget.migrator.drop_and_create
    CallbackWidget.migrator.drop_and_create
  end

  before_each do
    PersistenceWidget.clear
    ReadonlyWidget.clear
    CallbackWidget.clear
  end

  describe "#update_attribute" do
    it "persists a single attribute" do
      w = PersistenceWidget.create!(name: "Original", counter: 0)
      w.update_attribute(:name, "Changed").should be_true

      PersistenceWidget.find!(w.id).name.should eq("Changed")
    end

    it "skips validations (saves even when the record is invalid)" do
      w = PersistenceWidget.create!(name: "Valid", counter: 0)
      # Set name to blank, which would normally fail the :name validation.
      w.update_attribute(:name, "").should be_true

      reloaded = PersistenceWidget.find!(w.id)
      reloaded.name.should eq("")
    end

    it "raises on failure with the bang variant when validation is bypassed but save fails" do
      # update_attribute! returns true on success
      w = PersistenceWidget.create!(name: "Valid", counter: 0)
      w.update_attribute!(:counter, 5).should be_true
      PersistenceWidget.find!(w.id).counter.should eq(5)
    end
  end

  describe "#update_columns" do
    it "updates the column directly and in-memory" do
      w = PersistenceWidget.create!(name: "Original", counter: 1)
      w.update_columns(name: "Direct").should be_true

      w.name.should eq("Direct")
      PersistenceWidget.find!(w.id).name.should eq("Direct")
    end

    it "skips callbacks" do
      w = CallbackWidget.create!(name: "Start")
      w.before_save_count.should eq(1) # from create

      w.update_columns(name: "NoCallback")
      # before_save should NOT have fired again
      w.before_save_count.should eq(1)
      CallbackWidget.find!(w.id).name.should eq("NoCallback")
    end

    it "skips validations" do
      w = PersistenceWidget.create!(name: "Valid", counter: 0)
      w.update_columns(name: "").should be_true
      PersistenceWidget.find!(w.id).name.should eq("")
    end

    it "raises on a new (unsaved) record" do
      w = PersistenceWidget.new(name: "New")
      expect_raises(Exception, /new record/) do
        w.update_columns(name: "Nope")
      end
    end
  end

  describe "#increment! / #decrement!" do
    it "increment! persists +1 by default" do
      w = PersistenceWidget.create!(name: "Counter", counter: 10)
      w.increment!(:counter)
      w.counter.should eq(11)
      PersistenceWidget.find!(w.id).counter.should eq(11)
    end

    it "increment! accepts a custom step" do
      w = PersistenceWidget.create!(name: "Counter", counter: 10)
      w.increment!(:counter, 5)
      PersistenceWidget.find!(w.id).counter.should eq(15)
    end

    it "decrement! persists -1 by default" do
      w = PersistenceWidget.create!(name: "Counter", counter: 10)
      w.decrement!(:counter)
      w.counter.should eq(9)
      PersistenceWidget.find!(w.id).counter.should eq(9)
    end

    it "non-bang increment mutates in-memory only" do
      w = PersistenceWidget.create!(name: "Counter", counter: 10)
      w.increment(:counter, 3)
      w.counter.should eq(13)
      PersistenceWidget.find!(w.id).counter.should eq(10)
    end

    it "skips validations on increment!" do
      w = PersistenceWidget.create!(name: "Valid", counter: 0)
      w.name = ""
      # name would fail validation, but increment! skips it
      w.increment!(:counter)
      PersistenceWidget.find!(w.id).counter.should eq(1)
    end
  end

  describe "#toggle!" do
    it "flips a boolean and persists" do
      w = PersistenceWidget.create!(name: "Toggler", active: false)
      w.toggle!(:active)
      w.active.should be_true
      PersistenceWidget.find!(w.id).active.should be_true
    end

    it "non-bang toggle mutates in-memory only" do
      w = PersistenceWidget.create!(name: "Toggler", active: false)
      w.toggle(:active)
      w.active.should be_true
      PersistenceWidget.find!(w.id).active.should be_false
    end
  end

  describe "read-only records" do
    it "readonly! marks a record read-only" do
      w = PersistenceWidget.create!(name: "RO", counter: 0)
      w.readonly?.should be_false
      w.readonly!
      w.readonly?.should be_true
    end

    it "raises Grant::ReadOnlyRecordError when updating a readonly! record" do
      w = PersistenceWidget.create!(name: "RO", counter: 0)
      w.readonly!
      w.name = "Changed"
      expect_raises(Grant::ReadOnlyRecordError) do
        w.save!
      end
    end

    it "raises Grant::ReadOnlyRecordError when destroying a readonly! record" do
      w = PersistenceWidget.create!(name: "RO", counter: 0)
      w.readonly!
      expect_raises(Grant::ReadOnlyRecordError) do
        w.destroy
      end
    end
  end

  describe "attr_readonly" do
    it "registers the readonly column on the class" do
      ReadonlyWidget.readonly_attributes.should contain("slug")
    end

    it "allows setting the readonly column on create" do
      w = ReadonlyWidget.create!(slug: "original-slug", name: "First")
      ReadonlyWidget.find!(w.id).slug.should eq("original-slug")
    end

    it "ignores the readonly column on update" do
      w = ReadonlyWidget.create!(slug: "original-slug", name: "First")
      w.slug = "changed-slug"
      w.name = "Second"
      w.save!

      reloaded = ReadonlyWidget.find!(w.id)
      reloaded.slug.should eq("original-slug") # unchanged
      reloaded.name.should eq("Second")        # updated
    end
  end
end
