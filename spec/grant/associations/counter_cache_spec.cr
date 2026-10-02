require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class CcShelf < Grant::Base
    connection {{ adapter_literal }}
    table cc_shelves
    column id : Int64, primary: true
    column name : String?
    column cc_categories_count : Int32 = 0
    column cc_notches_count : Int32 = 0
    column total_tags : Int32 = 0

    has_many :cc_categories, class_name: CcCategory, foreign_key: :cc_shelf_id
    has_many :cc_notches, class_name: CcNotch, foreign_key: :cc_shelf_id
    has_many :cc_tags, class_name: CcTag, foreign_key: :cc_shelf_id
    has_many :cc_plains, class_name: CcPlain, foreign_key: :cc_shelf_id
  end

  # The model name pluralizes irregularly: Category -> categories.
  class CcCategory < Grant::Base
    connection {{ adapter_literal }}
    table cc_categories
    column id : Int64, primary: true
    column cc_shelf_id : Int64?
    belongs_to :cc_shelf, class_name: CcShelf, foreign_key: cc_shelf_id : Int64?, counter_cache: true, optional: true
  end

  class CcNotch < Grant::Base
    connection {{ adapter_literal }}
    table cc_notches
    column id : Int64, primary: true
    column cc_shelf_id : Int64?
    belongs_to :cc_shelf, class_name: CcShelf, foreign_key: cc_shelf_id : Int64?, counter_cache: {column: :cc_notches_count, active: false}, optional: true
  end

  class CcPlain < Grant::Base
    connection {{ adapter_literal }}
    table cc_plains
    column id : Int64, primary: true
    column cc_shelf_id : Int64?
  end

  class CcStamp < Grant::Base
    connection {{ adapter_literal }}
    table cc_stamps
    column id : Int64, primary: true
    column cc_stampable_id : Int64?
    column cc_stampable_type : String?
    belongs_to :cc_stampable, polymorphic: true, counter_cache: true, optional: true
  end

  class CcQuietStamp < Grant::Base
    connection {{ adapter_literal }}
    table cc_quiet_stamps
    column id : Int64, primary: true
    column cc_quiet_id : Int64?
    column cc_quiet_type : String?
    belongs_to :cc_quiet, polymorphic: true, counter_cache: {column: :cc_stamps_count, active: false}, optional: true
  end

  class CcStampHost < Grant::Base
    connection {{ adapter_literal }}
    table cc_stamp_hosts
    column id : Int64, primary: true
    column cc_stamps_count : Int32 = 0
    has_many :cc_stamps, as: :cc_stampable
  end

  class CcTag < Grant::Base
    connection {{ adapter_literal }}
    table cc_tags
    column id : Int64, primary: true
    column cc_shelf_id : Int64?
    belongs_to :cc_shelf, class_name: CcShelf, foreign_key: cc_shelf_id : Int64?, counter_cache: :total_tags, optional: true
  end
{% end %}

private def shelf_count(shelf : CcShelf) : Int32
  CcShelf.find!(shelf.id).cc_categories_count
end

describe "belongs_to counter_cache:" do
  before_all do
    CcShelf.migrator.drop_and_create
    CcCategory.migrator.drop_and_create
    CcNotch.migrator.drop_and_create
    CcTag.migrator.drop_and_create
    CcPlain.migrator.drop_and_create
    CcStamp.migrator.drop_and_create
    CcQuietStamp.migrator.drop_and_create
    CcStampHost.migrator.drop_and_create
  end

  before_each do
    CcCategory.clear
    CcNotch.clear
    CcTag.clear
    CcStamp.clear
    CcQuietStamp.clear
    CcStampHost.clear
    CcShelf.clear
  end

  describe "the default column name" do
    it "pluralizes the model name (Category gives categories_count)" do
      Grant::CounterCache.default_column("CcCategory").should eq("cc_categories_count")
      Grant::CounterCache.default_column("Post").should eq("posts_count")
      Grant::CounterCache.default_column("Box").should eq("boxes_count")
      Grant::CounterCache.default_column("Day").should eq("days_count")
      Grant::CounterCache.default_column("Person").should eq("people_count")
    end

    it "is maintained on create and destroy with atomic SQL" do
      shelf = CcShelf.create!(name: "s")

      statements = StatementRecorder.statements { CcCategory.create!(cc_shelf_id: shelf.id) }
      counter_update = statements.find { |sql| sql.upcase.starts_with?("UPDATE") && sql.includes?("cc_shelves") }
      counter_update.should_not be_nil
      counter_update.not_nil!.should contain("COALESCE")
      shelf_count(shelf).should eq(1)

      category = CcCategory.create!(cc_shelf_id: shelf.id)
      shelf_count(shelf).should eq(2)

      category.destroy
      shelf_count(shelf).should eq(1)
    end

    it "moves the count when the foreign key changes" do
      one = CcShelf.create!(name: "1")
      two = CcShelf.create!(name: "2")
      category = CcCategory.create!(cc_shelf_id: one.id)

      category.cc_shelf_id = two.id
      category.save!

      shelf_count(one).should eq(0)
      shelf_count(two).should eq(1)
    end

    it "updates a parent that is already loaded on the child in memory" do
      shelf = CcShelf.create!(name: "s")
      category = CcCategory.new
      category.cc_shelf = shelf
      category.save!

      shelf.cc_categories_count.should eq(1)
      shelf.changed?.should be_false
    end

    it "leaves the parent alone when the parent's dependent: :destroy removes the child" do
      shelf = CcShelf.create!(name: "s")
      CcCategory.create!(cc_shelf_id: shelf.id)
      category = CcCategory.find_by(cc_shelf_id: shelf.id).not_nil!
      category.destroyed_by_association = Grant::Reflection.new("CcShelf", "cc_categories", :has_many, CcCategory, "CcCategory", "cc_shelf_id", "id")

      statements = StatementRecorder.statements { category.destroy }

      StatementRecorder.count(statements, "UPDATE", "cc_shelves").should eq(0)
    end
  end

  describe "a polymorphic belongs_to" do
    it "uses the same pluralized default column" do
      host = CcStampHost.create!
      CcStamp.create!(cc_stampable: host)
      CcStamp.create!(cc_stampable: host)

      CcStampHost.find!(host.id).cc_stamps_count.should eq(2)
    end
  end

  describe "a polymorphic belongs_to with active: false" do
    it "leaves the column alone" do
      host = CcStampHost.create!
      CcQuietStamp.create!(cc_quiet: host)

      CcStampHost.find!(host.id).cc_stamps_count.should eq(0)
    end
  end

  describe "a named column" do
    it "is maintained" do
      shelf = CcShelf.create!(name: "s")
      CcTag.create!(cc_shelf_id: shelf.id)
      CcTag.create!(cc_shelf_id: shelf.id)

      CcShelf.find!(shelf.id).total_tags.should eq(2)
    end
  end

  describe "active: false" do
    it "does not maintain the column" do
      shelf = CcShelf.create!(name: "s")
      notch = CcNotch.create!(cc_shelf_id: shelf.id)

      CcShelf.find!(shelf.id).cc_notches_count.should eq(0)

      notch.destroy
      CcShelf.find!(shelf.id).cc_notches_count.should eq(0)
    end

    it "can still be repaired with reset_counters" do
      shelf = CcShelf.create!(name: "s")
      2.times { CcNotch.create!(cc_shelf_id: shelf.id) }

      CcShelf.reset_counters(shelf.id.not_nil!, :cc_notches)

      CcShelf.find!(shelf.id).cc_notches_count.should eq(2)
    end
  end

  describe ".reset_counters" do
    it "recounts with one correlated-subquery UPDATE and loads nothing" do
      shelf = CcShelf.create!(name: "s")
      3.times { CcCategory.create!(cc_shelf_id: shelf.id) }
      CcShelf.where(id: shelf.id).update_all({"cc_categories_count" => 99.as(Grant::Columns::Type)})

      statements = StatementRecorder.statements { CcShelf.reset_counters(shelf.id.not_nil!, :cc_categories) }

      writes = statements.select { |sql| sql.upcase.lstrip.starts_with?("UPDATE") }
      writes.size.should eq(1)
      writes.first.should contain("SELECT COUNT(*)")
      StatementRecorder.count(statements, "SELECT", "cc_shelves").should eq(0)
      shelf_count(shelf).should eq(3)
    end

    it "only touches the given row" do
      one = CcShelf.create!(name: "1")
      two = CcShelf.create!(name: "2")
      CcCategory.create!(cc_shelf_id: one.id)
      CcShelf.where(id: [one.id, two.id]).update_all({"cc_categories_count" => 50.as(Grant::Columns::Type)})

      CcShelf.reset_counters(one.id.not_nil!, :cc_categories)

      shelf_count(one).should eq(1)
      shelf_count(two).should eq(50)
    end

    it "raises for an association without a counter cache" do
      shelf = CcShelf.create!(name: "s")
      expect_raises(ArgumentError, /no counter cache/) { CcShelf.reset_counters(shelf.id.not_nil!, :cc_plains) }
    end

    it "raises for an unknown association" do
      shelf = CcShelf.create!(name: "s")
      expect_raises(Grant::AssociationNotFoundError) { CcShelf.reset_counters(shelf.id.not_nil!, :cc_bogus) }
    end
  end

  describe ".increment_counter and .decrement_counter" do
    it "adjust the column atomically" do
      shelf = CcShelf.create!(name: "s")

      CcShelf.increment_counter(:cc_categories_count, shelf.id.not_nil!).should eq(1)
      CcShelf.increment_counter(:cc_categories_count, shelf.id.not_nil!, by: 4)
      shelf_count(shelf).should eq(5)

      CcShelf.decrement_counter(:cc_categories_count, shelf.id.not_nil!, by: 2)
      shelf_count(shelf).should eq(3)
    end

    it "can touch the row" do
      shelf = CcShelf.create!(name: "s")

      statements = StatementRecorder.statements do
        CcShelf.increment_counter(:cc_categories_count, shelf.id.not_nil!, touch: true)
      end

      StatementRecorder.count(statements, "UPDATE", "cc_shelves").should eq(1)
    end
  end

  describe "has_many size" do
    it "reads the cached column without a COUNT when the association is not loaded" do
      shelf = CcShelf.create!(name: "s")
      2.times { CcCategory.create!(cc_shelf_id: shelf.id) }
      shelf = CcShelf.find!(shelf.id)

      size = 0_i64
      statements = StatementRecorder.statements { size = shelf.cc_categories.size }

      size.should eq(2)
      statements.should be_empty
    end

    it "counts the loaded records when the association is loaded" do
      shelf = CcShelf.create!(name: "s")
      CcCategory.create!(cc_shelf_id: shelf.id)
      shelf = CcShelf.find!(shelf.id)
      shelf.cc_categories.load_target
      CcShelf.where(id: shelf.id).update_all({"cc_categories_count" => 42.as(Grant::Columns::Type)})

      shelf.cc_categories.size.should eq(1)
    end

    it "does not trust an inactive counter" do
      shelf = CcShelf.create!(name: "s")
      2.times { CcNotch.create!(cc_shelf_id: shelf.id) }
      shelf = CcShelf.find!(shelf.id)

      shelf.cc_notches.size.should eq(2)
    end
  end

  describe "collection removal" do
    it "delete decrements the parent's count in the database and in memory" do
      shelf = CcShelf.create!(name: "s")
      first = CcCategory.create!(cc_shelf_id: shelf.id)
      CcCategory.create!(cc_shelf_id: shelf.id)
      shelf = CcShelf.find!(shelf.id)

      shelf.cc_categories.delete(first)

      shelf_count(shelf).should eq(1)
      shelf.cc_categories_count.should eq(1)
    end

    it "delete_all and clear reset the count" do
      shelf = CcShelf.create!(name: "s")
      3.times { CcCategory.create!(cc_shelf_id: shelf.id) }
      shelf = CcShelf.find!(shelf.id)

      shelf.cc_categories.delete_all.should eq(3)
      shelf_count(shelf).should eq(0)

      2.times { CcCategory.create!(cc_shelf_id: shelf.id) }
      shelf_count(shelf).should eq(2)
      shelf.cc_categories.clear
      shelf_count(shelf).should eq(0)
    end

    it "destroy runs the child's callbacks once, not twice" do
      shelf = CcShelf.create!(name: "s")
      first = CcCategory.create!(cc_shelf_id: shelf.id)
      CcCategory.create!(cc_shelf_id: shelf.id)
      shelf = CcShelf.find!(shelf.id)

      shelf.cc_categories.destroy(first)

      shelf_count(shelf).should eq(1)
    end

    it "appending an existing record counts it" do
      shelf = CcShelf.create!(name: "s")
      loose = CcCategory.create!
      shelf = CcShelf.find!(shelf.id)

      shelf.cc_categories << loose

      shelf_count(shelf).should eq(1)
    end
  end
end
