require "../../spec_helper"

class CollectionMetricOwner < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table collection_metric_owners

  column id : Int64, primary: true
  column label : String

  has_many :posts, class_name: CollectionMetricPost, foreign_key: :collection_metric_owner_id
end

class CollectionMetricPost < Grant::Base
  connection {{ CURRENT_ADAPTER }}
  table collection_metric_posts

  column id : Int64, primary: true
  column collection_metric_owner_id : Int64?
  column is_visible : Bool

  default_scope { where(is_visible: true) }
end

describe "association collection query methods" do
  before_all do
    CollectionMetricOwner.migrator.drop_and_create
    CollectionMetricPost.migrator.drop_and_create
  end

  before_each do
    CollectionMetricPost.clear
    CollectionMetricOwner.clear
  end

  it "counts database rows with owner and default scopes" do
    owner = CollectionMetricOwner.create!(label: "with posts")
    2.times do
      CollectionMetricPost.create!(collection_metric_owner_id: owner.id, is_visible: true)
    end
    CollectionMetricPost.create!(collection_metric_owner_id: owner.id, is_visible: false)

    owner.posts.count.should eq(2_i64)
    owner.posts.size.should eq(2)
    owner.posts.length.should eq(2)
    owner.posts.empty?.should be_false
    owner.posts.any?.should be_true
    owner.posts.none?.should be_false
  end

  it "uses a loaded target for size and enumerable predicates" do
    owner = CollectionMetricOwner.create!(label: "loaded posts")
    first_post = CollectionMetricPost.create!(collection_metric_owner_id: owner.id, is_visible: true)
    CollectionMetricPost.create!(collection_metric_owner_id: owner.id, is_visible: true)
    owner.set_loaded_association("posts", [first_post])

    owner.posts.size.should eq(1)
    owner.posts.length.should eq(1)
    owner.posts.count.should eq(2_i64)
    owner.posts.empty?.should be_false
    owner.posts.any?.should be_true
    owner.posts.none?.should be_false
  end

  it "reports empty loaded and unloaded associations" do
    owner = CollectionMetricOwner.create!(label: "no posts")

    owner.posts.count.should eq(0_i64)
    owner.posts.size.should eq(0)
    owner.posts.length.should eq(0)
    owner.posts.empty?.should be_true
    owner.posts.any?.should be_false
    owner.posts.none?.should be_true

    owner.set_loaded_association("posts", [] of CollectionMetricPost)
    owner.posts.size.should eq(0)
    owner.posts.empty?.should be_true
    owner.posts.any?.should be_false
    owner.posts.none?.should be_true
  end
end
