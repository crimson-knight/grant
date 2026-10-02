require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SlOwner < Grant::Base
    connection {{ adapter_literal }}
    table sl_owners
    column id : Int64, primary: true
    column name : String
    has_many :sl_items, class_name: SlItem, foreign_key: :sl_owner_id
    has_many :sl_strict_items, class_name: SlItem, foreign_key: :sl_owner_id, strict_loading: true
    has_many :sl_lenient_items, class_name: SlItem, foreign_key: :sl_owner_id, strict_loading: false
    has_one :sl_detail, class_name: SlDetail, foreign_key: :sl_owner_id
  end

  class SlItem < Grant::Base
    connection {{ adapter_literal }}
    table sl_items
    column id : Int64, primary: true
    column label : String
    column sl_owner_id : Int64?
    belongs_to :sl_owner, class_name: SlOwner, foreign_key: :sl_owner_id, optional: true
    has_many :sl_tags, class_name: SlTag, foreign_key: :sl_item_id
  end

  class SlTag < Grant::Base
    connection {{ adapter_literal }}
    table sl_tags
    column id : Int64, primary: true
    column label : String
    column sl_item_id : Int64?
  end

  class SlDetail < Grant::Base
    connection {{ adapter_literal }}
    table sl_details
    column id : Int64, primary: true
    column note : String
    column sl_owner_id : Int64?
    belongs_to :sl_owner, class_name: SlOwner, foreign_key: :sl_owner_id, optional: true
  end

  class SlPost < Grant::Base
    connection {{ adapter_literal }}
    table sl_posts
    column id : Int64, primary: true
    column title : String
    has_many :sl_comments, as: :commentable, class_name: SlComment
    has_one :sl_cover, as: :commentable, class_name: SlCover
  end

  class SlComment < Grant::Base
    connection {{ adapter_literal }}
    table sl_comments
    column id : Int64, primary: true
    column body : String
    belongs_to :commentable, polymorphic: true, optional: true
  end

  class SlCover < Grant::Base
    connection {{ adapter_literal }}
    table sl_covers
    column id : Int64, primary: true
    column url : String
    column commentable_id : Int64?
    column commentable_type : String?
  end

  class SlDefault < Grant::Base
    connection {{ adapter_literal }}
    table sl_defaults
    column id : Int64, primary: true
    column name : String
    has_many :sl_default_kids, class_name: SlDefaultKid, foreign_key: :sl_default_id
  end

  class SlDefaultKid < Grant::Base
    connection {{ adapter_literal }}
    table sl_default_kids
    column id : Int64, primary: true
    column sl_default_id : Int64?
  end
{% end %}

def seed_sl : SlOwner
  owner = SlOwner.create!(name: "o")
  item = SlItem.create!(label: "i", sl_owner_id: owner.id)
  SlTag.create!(label: "t", sl_item_id: item.id)
  SlDetail.create!(note: "d", sl_owner_id: owner.id)
  owner
end

describe "strict loading" do
  before_all do
    {% for model in [SlOwner, SlItem, SlTag, SlDetail, SlPost, SlComment, SlCover, SlDefault, SlDefaultKid] %}
      {{ model }}.migrator.drop_and_create
    {% end %}
  end

  before_each do
    {% for model in [SlTag, SlItem, SlDetail, SlOwner, SlComment, SlCover, SlPost, SlDefaultKid, SlDefault] %}
      {{ model }}.clear
    {% end %}
  end

  describe "on a record" do
    it "raises on every kind of lazy association read" do
      owner = seed_sl
      strict = SlOwner.find!(owner.id).strict_loading!
      strict.strict_loading?.should be_true
      expect_raises(Grant::StrictLoadingViolationError) { strict.sl_items.to_a }
      expect_raises(Grant::StrictLoadingViolationError) { strict.sl_items.count }
      expect_raises(Grant::StrictLoadingViolationError) { strict.sl_detail }
      item = SlItem.find!(SlItem.first.not_nil!.id).strict_loading!
      expect_raises(Grant::StrictLoadingViolationError) { item.sl_owner }
    end

    it "raises for polymorphic has_many, has_one, and belongs_to" do
      post = SlPost.create!(title: "p")
      comment = SlComment.create!(body: "c", commentable_id: post.id, commentable_type: "SlPost")
      SlCover.create!(url: "u", commentable_id: post.id, commentable_type: "SlPost")

      strict_post = SlPost.find!(post.id).strict_loading!
      expect_raises(Grant::StrictLoadingViolationError) { strict_post.sl_comments.to_a }
      expect_raises(Grant::StrictLoadingViolationError) { strict_post.sl_cover }
      expect_raises(Grant::StrictLoadingViolationError) { SlComment.find!(comment.id).strict_loading!.commentable }
    end

    it "allows preloaded associations and can be turned off" do
      owner = seed_sl
      loaded = SlOwner.includes(:sl_items, :sl_detail).where(id: owner.id).select.first.strict_loading!
      loaded.sl_items.size.should eq(1)
      loaded.sl_detail.should_not be_nil
      loaded.strict_loading!(false)
      loaded.strict_loading?.should be_false
      loaded.sl_items.first.should_not be_nil
    end

    it "propagates to records loaded through a strict owner" do
      owner = seed_sl
      loaded = SlOwner.strict_loading.includes(:sl_items).where(id: owner.id).select.first
      loaded.strict_loading?.should be_true
      item = loaded.sl_items.first.not_nil!
      item.strict_loading?.should be_true
      expect_raises(Grant::StrictLoadingViolationError) { item.sl_tags.to_a }
    end
  end

  describe "on an association" do
    it "strict_loading: true raises for a record that is not strict" do
      owner = SlOwner.find!(seed_sl.id)
      owner.strict_loading?.should be_false
      expect_raises(Grant::StrictLoadingViolationError, /sl_strict_items/) { owner.sl_strict_items.to_a }
      owner.sl_items.to_a.size.should eq(1)
      SlOwner.includes(:sl_strict_items).where(id: owner.id).select.first.sl_strict_items.size.should eq(1)
    end

    it "strict_loading: false wins over a strict record" do
      owner = SlOwner.find!(seed_sl.id).strict_loading!
      owner.sl_lenient_items.to_a.size.should eq(1)
      expect_raises(Grant::StrictLoadingViolationError) { owner.sl_items.to_a }
    end
  end

  describe "by default for a model" do
    it "makes every record of that model strict" do
      parent = SlDefault.create!(name: "p")
      SlDefaultKid.create!(sl_default_id: parent.id)
      begin
        SlDefault.strict_loading_by_default = true
        found = SlDefault.find!(parent.id)
        found.strict_loading?.should be_true
        expect_raises(Grant::StrictLoadingViolationError) { found.sl_default_kids.to_a }
        SlDefault.includes(:sl_default_kids).where(id: parent.id).select.first.sl_default_kids.size.should eq(1)
        found.strict_loading!(false)
        found.sl_default_kids.size.should eq(1)
      ensure
        SlDefault.strict_loading_by_default = false
      end
      SlDefault.find!(parent.id).strict_loading?.should be_false
    end
  end

  describe "in n_plus_one_only mode" do
    it "lets the record load its own associations and marks has_many children strict" do
      owner = SlOwner.find!(seed_sl.id).strict_loading!(mode: :n_plus_one_only)
      owner.strict_loading_n_plus_one_only?.should be_true
      items = owner.sl_items.to_a
      items.size.should eq(1)
      items.first.strict_loading?.should be_true
      expect_raises(Grant::StrictLoadingViolationError) { items.first.sl_tags.to_a }

      detail = owner.sl_detail.not_nil!
      detail.strict_loading?.should be_false
      detail.sl_owner.should_not be_nil
    end

    it "does not use a per-record load counter or rewrite queries" do
      owner = SlOwner.find!(seed_sl.id).strict_loading!(mode: :n_plus_one_only)
      AssociationQueryCounter.selects { owner.sl_items.to_a }.should eq(1)
    end
  end

  describe "violation action" do
    it "logs instead of raising when configured" do
      owner = SlOwner.find!(seed_sl.id).strict_loading!
      begin
        Grant.settings.strict_loading_violation = :log
        result = nil
        Log.capture("grant.association", Log::Severity::Warn) do |logs|
          result = owner.sl_items.to_a
          logs.check(:warn, /SlOwner#sl_items was not preloaded/)
        end
        result.not_nil!.size.should eq(1)
      ensure
        Grant.settings.strict_loading_violation = :raise
      end
      expect_raises(Grant::StrictLoadingViolationError) { owner.sl_detail }
    end
  end
end
