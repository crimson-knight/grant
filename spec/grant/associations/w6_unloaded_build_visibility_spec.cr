require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6bOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6b_owners
    column id : Int64, primary: true
    column name : String?
    has_many :w6b_posts, class_name: W6bPost, foreign_key: :w6b_owner_id
    has_many :w6b_links, class_name: W6bLink, foreign_key: :w6b_owner_id
    has_many :w6b_tags, class_name: W6bTag, through: :w6b_links
  end

  class W6bPost < Grant::Base
    connection {{ adapter_literal }}
    table w6b_posts
    column id : Int64, primary: true
    column title : String?
    column w6b_owner_id : Int64?
  end

  class W6bTag < Grant::Base
    connection {{ adapter_literal }}
    table w6b_tags
    column id : Int64, primary: true
    column label : String?
  end

  class W6bLink < Grant::Base
    connection {{ adapter_literal }}
    table w6b_links
    column id : Int64, primary: true
    column w6b_owner_id : Int64?
    column w6b_tag_id : Int64?
    belongs_to :w6b_owner, class_name: W6bOwner, foreign_key: :w6b_owner_id, optional: true
    belongs_to :w6b_tag, class_name: W6bTag, foreign_key: :w6b_tag_id, optional: true
  end
{% end %}

describe "records built on a collection that was never loaded" do
  before_all do
    W6bOwner.migrator.drop_and_create
    W6bPost.migrator.drop_and_create
    W6bTag.migrator.drop_and_create
    W6bLink.migrator.drop_and_create
  end

  before_each do
    W6bLink.clear
    W6bTag.clear
    W6bPost.clear
    W6bOwner.clear
  end

  it "shows up when the association is read again, merged with the stored rows" do
    owner = W6bOwner.create!(name: "o")
    W6bPost.create!(title: "stored", w6b_owner_id: owner.id)

    built = owner.w6b_posts.build(title: "built")

    titles = owner.w6b_posts.compact_map(&.title).sort!
    titles.should eq(["built", "stored"])
    owner.w6b_posts.to_a.any?(&.same?(built)).should be_true
    W6bPost.count.should eq(1)
  end

  it "counts in size, any? and empty? but not in the database count" do
    owner = W6bOwner.create!(name: "o")
    owner.w6b_posts.empty?.should be_true

    owner.w6b_posts.build(title: "built")

    owner.w6b_posts.size.should eq(1)
    owner.w6b_posts.any?.should be_true
    owner.w6b_posts.empty?.should be_false
    owner.w6b_posts.count.should eq(0)
  end

  it "is visible to first, last and find_by without a save" do
    owner = W6bOwner.create!(name: "o")
    stored = W6bPost.create!(title: "stored", w6b_owner_id: owner.id)
    built = owner.w6b_posts.build(title: "built")

    owner.w6b_posts.first.not_nil!.id.should eq(stored.id)
    owner.w6b_posts.last.not_nil!.same?(built).should be_true
    owner.w6b_posts.find_by(title: "built").not_nil!.same?(built).should be_true
  end

  it "does not duplicate the record once the owner is saved" do
    owner = W6bOwner.create!(name: "o")
    built = owner.w6b_posts.build(title: "built")

    owner.name = "renamed"
    owner.save!

    built.persisted?.should be_true
    owner.w6b_posts.map(&.id).should eq([built.id])
    owner.w6b_posts.size.should eq(1)
  end

  it "is visible on an owner that is not saved yet" do
    owner = W6bOwner.new(name: "new")

    owner.w6b_posts.build(title: "a")
    owner.w6b_posts.build(title: "b")

    owner.w6b_posts.compact_map(&.title).sort!.should eq(["a", "b"])
    owner.w6b_posts.size.should eq(2)
    owner.save!
    W6bPost.where(w6b_owner_id: owner.id).count.should eq(2)
  end

  it "is visible on a has_many :through collection" do
    owner = W6bOwner.create!(name: "o")
    stored = W6bTag.create!(label: "stored")
    owner.w6b_tags << stored

    built = owner.w6b_tags.build(label: "built")

    owner.w6b_tags.compact_map(&.label).sort!.should eq(["built", "stored"])
    owner.w6b_tags.size.should eq(2)
    owner.w6b_tags.any?.should be_true
    owner.w6b_tags.to_a.any?(&.same?(built)).should be_true
  end

  it "keeps the built record out of reads once it was deleted from memory by a reset" do
    owner = W6bOwner.create!(name: "o")
    owner.w6b_posts.build(title: "built")

    owner.reload
    owner.w6b_posts.to_a.size.should eq(0)
  end
end
