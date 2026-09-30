require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  # Tags attach to posts and photos through one polymorphic join table.
  class StTag < Grant::Base
    connection {{ adapter_literal }}
    table st_tags
    column id : Int64, primary: true
    column label : String
    column st_collector_id : Int64?
    has_many :st_taggings, class_name: StTagging, foreign_key: :st_tag_id
    has_many :st_posts, through: :st_taggings, source: :taggable, source_type: StPost
    has_many :st_photos, through: :st_taggings, source: :taggable, source_type: StPhoto
    has_many :st_featured_posts, -> { where(featured: true) }, through: :st_taggings, source: :taggable, source_type: StPost
    has_many :st_untyped_things, through: :st_taggings, source: :taggable, class_name: StPost
  end

  class StTagging < Grant::Base
    connection {{ adapter_literal }}
    table st_taggings
    column id : Int64, primary: true
    column st_tag_id : Int64?
    belongs_to :st_tag, class_name: StTag, foreign_key: :st_tag_id, optional: true
    belongs_to :taggable, polymorphic: true, optional: true
  end

  class StPost < Grant::Base
    connection {{ adapter_literal }}
    table st_posts
    column id : Int64, primary: true
    column title : String
    column featured : Bool = false
    has_many :st_taggings, class_name: StTagging, as: :taggable
  end

  class StPhoto < Grant::Base
    connection {{ adapter_literal }}
    table st_photos
    column id : Int64, primary: true
    column caption : String
    has_many :st_taggings, class_name: StTagging, as: :taggable
  end

  # A through association whose source is itself a polymorphic through.
  class StCollector < Grant::Base
    connection {{ adapter_literal }}
    table st_collectors
    column id : Int64, primary: true
    column name : String
    has_many :st_tags, class_name: StTag, foreign_key: :st_collector_id
    has_many :st_collected_posts, through: :st_tags, source: :st_posts, class_name: StPost
  end
{% end %}

private def st_tag_it(tag : StTag, target : Grant::Base) : StTagging
  tagging = StTagging.new(st_tag_id: tag.id)
  tagging.taggable = target
  tagging.save!
  tagging
end

# Posts and photos deliberately share an id value, so a missing type predicate
# would return the photo's tagging as a post.
private def st_fixture
  tag = StTag.create!(label: "crystal")
  other = StTag.create!(label: "ruby")
  first_post = StPost.create!(id: 901_i64, title: "first", featured: true)
  second_post = StPost.create!(id: 902_i64, title: "second")
  photo = StPhoto.create!(id: 901_i64, caption: "shot")
  photo.id.should eq first_post.id
  st_tag_it(tag, first_post)
  st_tag_it(tag, second_post)
  st_tag_it(tag, photo)
  st_tag_it(other, second_post)
  {tag, other, first_post, second_post, photo}
end

describe "has_many :through with source_type" do
  before_all do
    StTag.migrator.drop_and_create
    StTagging.migrator.drop_and_create
    StPost.migrator.drop_and_create
    StPhoto.migrator.drop_and_create
    StCollector.migrator.drop_and_create
  end

  before_each do
    StTagging.clear
    StTag.clear
    StPost.clear
    StPhoto.clear
    StCollector.clear
  end

  it "reads only targets of the named type" do
    tag, other, first_post, second_post, photo = st_fixture
    tag.st_posts.to_a.map(&.title).sort!.should eq ["first", "second"]
    tag.st_photos.to_a.map(&.caption).should eq ["shot"]
    other.st_posts.to_a.map(&.title).should eq ["second"]
    other.st_photos.to_a.should be_empty
    photo.id.should eq first_post.id
    second_post.id.should_not be_nil
  end

  it "adds the type predicate to the one statement it runs" do
    tag, _ = st_fixture
    statements = AssociationQueryCounter.statements { tag.st_posts.to_a }
    statements.size.should eq 1
    statements.first.should contain("StPost")
  end

  it "supports the collection readers" do
    tag, other, _, second_post = st_fixture
    tag.st_posts.count.should eq 2
    tag.st_photos.count.should eq 1
    other.st_photos.exists?.should be_false
    other.st_posts.exists?.should be_true
    tag.st_posts.where(title: "second").to_a.map(&.id).should eq [second_post.id]
    tag.st_posts.find(second_post.id).try(&.title).should eq "second"
    tag.st_posts.ids.map(&.to_s).sort!.should eq StPost.all.map(&.id.to_s).sort!
  end

  it "applies an association scope to the typed targets" do
    tag, _ = st_fixture
    tag.st_featured_posts.to_a.map(&.title).should eq ["first"]
  end

  it "preloads with one query per hop and the same records as the lazy reader" do
    st_fixture
    lazy = StTag.order(:id).select.to_a.map { |tag| tag.st_posts.to_a.map(&.title).sort! }
    statements = AssociationQueryCounter.statements do
      StTag.includes(:st_posts).order(:id).select.to_a.map do |tag|
        tag.association_loaded?(:st_posts).should be_true
        tag.st_posts.to_a.map(&.title).sort!
      end.should eq lazy
    end
    # tags, taggings, posts: the photo tagging is never followed
    statements.size.should eq 3
  end

  it "preloads two typed sources of one owner without mixing them up" do
    st_fixture
    tags = StTag.includes(:st_posts, :st_photos).order(:id).select.to_a
    tags.map { |tag| tag.st_posts.to_a.map(&.title).sort! }.should eq [["first", "second"], ["second"]]
    tags.map { |tag| tag.st_photos.to_a.map(&.caption) }.should eq [["shot"], [] of String]
  end

  it "reads through a through whose source has a source_type" do
    tag, other, _, second_post = st_fixture
    collector = StCollector.create!(name: "kim")
    tag.update!(st_collector_id: collector.id)
    other.update!(st_collector_id: collector.id)
    collector.st_collected_posts.to_a.map(&.title).sort!.should eq ["first", "second"]
    collector.st_collected_posts.count.should eq 2
    second_post.id.should_not be_nil
    StCollector.includes(:st_collected_posts).select.to_a.first.st_collected_posts.to_a.map(&.title).sort!.should eq ["first", "second"]
  end

  it "adds and removes targets with the type written to the join row" do
    tag, _, first_post, second_post, photo = st_fixture
    fresh_post = StPost.create!(id: 903_i64, title: "fresh")
    tag.st_posts << fresh_post
    tagging = StTagging.where(st_tag_id: tag.id, taggable_id: fresh_post.id).first!
    tagging.taggable_type.should eq "StPost"
    tag.reload_st_posts.to_a.map(&.title).sort!.should eq ["first", "fresh", "second"]

    tag.st_posts.delete(first_post)
    tag.reload_st_posts.to_a.map(&.title).sort!.should eq ["fresh", "second"]
    # The photo that shares first_post's id keeps its tagging.
    tag.st_photos.reload.to_a.map(&.id).should eq [photo.id]
    StTagging.where(st_tag_id: tag.id, taggable_type: "StPhoto").count.should eq 1
    second_post.id.should_not be_nil
  end

  it "raises a named error for a polymorphic source without source_type" do
    tag, _ = st_fixture
    expect_raises(Grant::Associations::ThroughChainError, /source_type/) { tag.st_untyped_things.to_a }
  end
end
