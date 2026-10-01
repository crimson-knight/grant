require "../../spec_helper"

# where.associated / where.missing across scoped, has_one, composite-key and
# nested/polymorphic-source through associations.
class W6wmAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_authors

  column id : Int64, primary: true
  column name : String?

  has_many :posts, class_name: W6wmPost, foreign_key: author_id
  has_many :published_posts, -> { where(published: true) }, class_name: W6wmPost, foreign_key: author_id
  has_many :featured_posts, ->(q : Grant::Query::Builder(W6wmPost)) { q.where(published: true).where(score: 5) }, class_name: W6wmPost, foreign_key: author_id
  has_one :public_profile, -> { where(is_public: true) }, class_name: W6wmProfile, foreign_key: author_id
  has_one :profile, class_name: W6wmProfile, foreign_key: author_id
  has_many :approved_comments, -> { where(approved: true) }, class_name: W6wmComment, through: :posts, source: :comments
  has_many :comments, class_name: W6wmComment, through: :posts, source: :comments
  has_many :recent_tags, class_name: W6wmTag, through: :published_posts, source: :tags
  has_many :reactions, class_name: W6wmReaction, through: :posts, source: :reactions
  has_many :pinned_replies, class_name: W6wmReply, through: :comments, source: :replies
end

class W6wmPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_posts

  column id : Int64, primary: true
  column title : String?
  column published : Bool = false
  column score : Int32 = 0
  column author_id : Int64?

  belongs_to :author, class_name: W6wmAuthor, foreign_key: author_id, optional: true
  belongs_to :live_author, -> { where(name: "ann") }, class_name: W6wmAuthor, foreign_key: author_id, optional: true
  has_many :comments, class_name: W6wmComment, foreign_key: post_id
  has_many :taggings, class_name: W6wmTagging, foreign_key: post_id
  has_many :tags, class_name: W6wmTag, through: :taggings, source: :tag
  has_many :reactions, as: :reactable, class_name: W6wmReaction
end

class W6wmProfile < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_profiles

  column id : Int64, primary: true
  column author_id : Int64?
  column is_public : Bool = false
end

class W6wmComment < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_comments

  column id : Int64, primary: true
  column post_id : Int64?
  column approved : Bool = false

  has_many :replies, class_name: W6wmReply, foreign_key: comment_id
end

class W6wmReply < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_replies

  column id : Int64, primary: true
  column comment_id : Int64?
end

class W6wmTag < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_tags

  column id : Int64, primary: true
  column label : String?
end

class W6wmTagging < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_taggings

  column id : Int64, primary: true
  column post_id : Int64?
  column tag_id : Int64?

  belongs_to :tag, class_name: W6wmTag, foreign_key: tag_id, optional: true
end

# The reaction's owner is polymorphic; `Author#reactions` reaches the posts'
# reactions through the post (a has_many as:), and `W6wmPost` reads them back.
class W6wmReaction < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_reactions

  column id : Int64, primary: true
  column reactable_id : Int64?
  column reactable_type : String?
  column kind : String?

  belongs_to :reactable, polymorphic: true, optional: true
end

# Composite-key pair, with a scope on the has_many.
class W6wmLine < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_lines

  column id : Int64, primary: true
  column shop_id : Int64?
  column order_id : Int64?
  column shipped : Bool = false
end

class W6wmOrder < Grant::Base
  include Grant::CompositePrimaryKey

  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6wm_orders

  column shop_id : Int64, primary: true, auto: false
  column id : Int64, primary: true, auto: false
  composite_primary_key shop_id, id

  has_many :lines, class_name: W6wmLine, foreign_key: {:shop_id, :order_id}
  has_many :shipped_lines, -> { where(shipped: true) }, class_name: W6wmLine, foreign_key: {:shop_id, :order_id}
  has_one :first_line, class_name: W6wmLine, foreign_key: {:shop_id, :order_id}
end

private def author_names(relation : Grant::Query::Builder(W6wmAuthor)) : Array(String)
  relation.order(:id).select.map { |author| author.name.to_s }
end

private def post_titles(relation : Grant::Query::Builder(W6wmPost)) : Array(String)
  relation.order(:id).select.map { |post| post.title.to_s }
end

describe "where.associated / where.missing with scopes and has_one" do
  before_all do
    W6wmAuthor.migrator.drop_and_create
    W6wmPost.migrator.drop_and_create
    W6wmProfile.migrator.drop_and_create
    W6wmComment.migrator.drop_and_create
    W6wmReply.migrator.drop_and_create
    W6wmTag.migrator.drop_and_create
    W6wmTagging.migrator.drop_and_create
    W6wmReaction.migrator.drop_and_create
    W6wmLine.migrator.drop_and_create
    W6wmOrder.migrator.drop_and_create
  end

  before_each do
    {% for model in %w(W6wmReply W6wmReaction W6wmTagging W6wmComment W6wmTag W6wmProfile W6wmPost W6wmAuthor W6wmLine W6wmOrder) %}
      {{ model.id }}.clear
    {% end %}

    # ann: a published and a draft post; bob: only a draft; cy: no posts.
    ann = W6wmAuthor.create!(name: "ann")
    bob = W6wmAuthor.create!(name: "bob")
    cy = W6wmAuthor.create!(name: "cy")
    ann_live = W6wmPost.create!(title: "ann live", published: true, score: 5, author_id: ann.id)
    ann_draft = W6wmPost.create!(title: "ann draft", published: false, score: 5, author_id: ann.id)
    bob_draft = W6wmPost.create!(title: "bob draft", published: false, score: 1, author_id: bob.id)
    W6wmPost.create!(title: "orphan", published: true, score: 5)

    W6wmProfile.create!(author_id: ann.id, is_public: true)
    W6wmProfile.create!(author_id: bob.id, is_public: false)

    # Comments: ann's live post has an approved one, bob's draft only a
    # pending one.
    approved = W6wmComment.create!(post_id: ann_live.id, approved: true)
    W6wmComment.create!(post_id: bob_draft.id, approved: false)
    W6wmReply.create!(comment_id: approved.id)

    ruby = W6wmTag.create!(label: "ruby")
    W6wmTagging.create!(post_id: ann_live.id, tag_id: ruby.id)
    W6wmTagging.create!(post_id: bob_draft.id, tag_id: ruby.id)

    W6wmReaction.create!(reactable_id: ann_draft.id, reactable_type: "W6wmPost", kind: "like")
    # Same id, different type: must not count for ann's posts.
    W6wmReaction.create!(reactable_id: bob_draft.id, reactable_type: "Other", kind: "like")

    W6wmOrder.create!(shop_id: 1_i64, id: 7_i64)
    W6wmOrder.create!(shop_id: 2_i64, id: 7_i64)
    W6wmOrder.create!(shop_id: 3_i64, id: 7_i64)
    W6wmLine.create!(shop_id: 1_i64, order_id: 7_i64, shipped: true)
    W6wmLine.create!(shop_id: 2_i64, order_id: 7_i64, shipped: false)
  end

  describe "scoped has_many" do
    it "applies the scope in associated and missing" do
      author_names(W6wmAuthor.where.associated(:published_posts)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:published_posts)).should eq(["bob", "cy"])
      # The unscoped association still sees every post.
      author_names(W6wmAuthor.where.associated(:posts)).should eq(["ann", "bob"])
    end

    it "applies a multi-condition scope lambda with a block argument" do
      author_names(W6wmAuthor.where.associated(:featured_posts)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:featured_posts)).should eq(["bob", "cy"])
    end

    it "binds the scope value instead of splicing it" do
      relation = W6wmAuthor.where.associated(:published_posts).where(name: "ann")
      author_names(relation).should eq(["ann"])
      relation.to_sql.should_not contain("'ann'")
    end

    it "keeps the parent unique and the relation countable" do
      W6wmAuthor.where.associated(:published_posts).count.should eq(1)
      W6wmAuthor.where.missing(:published_posts).count.should eq(2)
    end

    it "combines scoped names, plain names and other clauses in bind order" do
      relation = W6wmAuthor.where(name: ["ann", "bob"]).where.associated(:posts).where.missing(:published_posts).where.associated(:public_profile)
      author_names(relation).should eq([] of String)
      author_names(W6wmAuthor.where(name: ["ann", "bob"]).where.associated(:posts).where.associated(:public_profile)).should eq(["ann"])
    end

    it "applies the scope of a scoped belongs_to" do
      post_titles(W6wmPost.where.associated(:live_author)).should eq(["ann live", "ann draft"])
      post_titles(W6wmPost.where.missing(:live_author)).should eq(["bob draft", "orphan"])
    end
  end

  describe "has_one" do
    it "associated and missing work for a plain has_one" do
      author_names(W6wmAuthor.where.associated(:profile)).should eq(["ann", "bob"])
      author_names(W6wmAuthor.where.missing(:profile)).should eq(["cy"])
    end

    it "applies the scope of a scoped has_one" do
      author_names(W6wmAuthor.where.associated(:public_profile)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:public_profile)).should eq(["bob", "cy"])
    end
  end

  describe "composite foreign keys" do
    it "matches the whole key tuple for has_many and has_one" do
      W6wmOrder.where.associated(:lines).order(:shop_id).select.map(&.shop_id).should eq([1_i64, 2_i64])
      W6wmOrder.where.missing(:lines).select.map(&.shop_id).should eq([3_i64])
      W6wmOrder.where.associated(:first_line).count.should eq(2)
      W6wmOrder.where.missing(:first_line).select.map(&.shop_id).should eq([3_i64])
    end

    it "applies a scope on a composite association" do
      W6wmOrder.where.associated(:shipped_lines).select.map(&.shop_id).should eq([1_i64])
      W6wmOrder.where.missing(:shipped_lines).order(:shop_id).select.map(&.shop_id).should eq([2_i64, 3_i64])
    end
  end

  describe "through associations" do
    it "applies the scope declared on the through association to the target" do
      author_names(W6wmAuthor.where.associated(:approved_comments)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:approved_comments)).should eq(["bob", "cy"])
      author_names(W6wmAuthor.where.associated(:comments)).should eq(["ann", "bob"])
    end

    it "applies the scope of the association it goes through" do
      # recent_tags goes through published_posts: bob's tag sits on a draft.
      author_names(W6wmAuthor.where.associated(:recent_tags)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:recent_tags)).should eq(["bob", "cy"])
    end

    it "resolves a through association whose through is itself a through" do
      # pinned_replies goes through comments, which goes through posts.
      author_names(W6wmAuthor.where.associated(:pinned_replies)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:pinned_replies)).should eq(["bob", "cy"])
    end

    it "walks a source that is a polymorphic has_many as:" do
      author_names(W6wmAuthor.where.associated(:reactions)).should eq(["ann"])
      author_names(W6wmAuthor.where.missing(:reactions)).should eq(["bob", "cy"])
    end

    it "still rejects a polymorphic belongs_to, like ActiveRecord" do
      expect_raises(ArgumentError, /polymorphic/) { W6wmReaction.where.associated(:reactable) }
    end
  end
end
