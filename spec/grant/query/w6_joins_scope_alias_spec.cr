require "../../spec_helper"

# joins / left_joins: association scopes land in the ON clause, and a table
# reached a second time is aliased automatically.
class W6jAuthor < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6j_authors

  column id : Int64, primary: true
  column name : String?
  column manager_id : Int64?

  belongs_to :manager, class_name: W6jAuthor, foreign_key: manager_id, optional: true
  has_many :posts, class_name: W6jPost, foreign_key: author_id
  has_many :published_posts, -> { where(published: true) }, class_name: W6jPost, foreign_key: author_id
  has_many :titled_posts, ->(q : Grant::Query::Builder(W6jPost)) { q.where(title: "it's ok") }, class_name: W6jPost, foreign_key: author_id
  has_many :comments, class_name: W6jComment, foreign_key: author_id
  has_many :approved_post_comments, -> { where(approved: true) }, class_name: W6jComment, through: :posts, source: :comments
  has_many :visible_tags, class_name: W6jTag, through: :published_posts, source: :tags
end

class W6jPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6j_posts

  column id : Int64, primary: true
  column title : String?
  column published : Bool = false
  column author_id : Int64?

  belongs_to :author, class_name: W6jAuthor, foreign_key: author_id, optional: true
  has_many :comments, class_name: W6jComment, foreign_key: post_id
  has_many :taggings, class_name: W6jTagging, foreign_key: post_id
  has_many :tags, class_name: W6jTag, through: :taggings, source: :tag
end

class W6jComment < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6j_comments

  column id : Int64, primary: true
  column body : String?
  column approved : Bool = false
  column post_id : Int64?
  column author_id : Int64?

  belongs_to :post, class_name: W6jPost, foreign_key: post_id, optional: true
  belongs_to :target, polymorphic: true, optional: true
end

class W6jTag < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6j_tags

  column id : Int64, primary: true
  column label : String?
end

class W6jTagging < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table w6j_taggings

  column id : Int64, primary: true
  column post_id : Int64?
  column tag_id : Int64?

  belongs_to :tag, class_name: W6jTag, foreign_key: tag_id, optional: true
end

private def names(relation : Grant::Query::Builder(W6jAuthor)) : Array(String)
  relation.order(:id).select.map(&.name.to_s)
end

describe "joins scope in ON and automatic aliasing" do
  before_all do
    W6jAuthor.migrator.drop_and_create
    W6jPost.migrator.drop_and_create
    W6jComment.migrator.drop_and_create
    W6jTag.migrator.drop_and_create
    W6jTagging.migrator.drop_and_create
  end

  before_each do
    {% for model in %w[W6jTagging W6jTag W6jComment W6jPost W6jAuthor] %}
      {{ model.id }}.clear
    {% end %}

    boss = W6jAuthor.create!(name: "boss")
    ann = W6jAuthor.create!(name: "ann", manager_id: boss.id)
    bob = W6jAuthor.create!(name: "bob", manager_id: boss.id)
    W6jAuthor.create!(name: "cy")

    live = W6jPost.create!(title: "ann live", published: true, author_id: ann.id)
    draft = W6jPost.create!(title: "ann draft", published: false, author_id: ann.id)
    bob_draft = W6jPost.create!(title: "it's ok", published: false, author_id: bob.id)

    W6jComment.create!(body: "on live, approved", approved: true, post_id: live.id, author_id: bob.id)
    W6jComment.create!(body: "on draft, pending", approved: false, post_id: draft.id, author_id: ann.id)
    W6jComment.create!(body: "on bob draft, approved", approved: true, post_id: bob_draft.id, author_id: ann.id)

    ruby = W6jTag.create!(label: "ruby")
    W6jTagging.create!(post_id: live.id, tag_id: ruby.id)
    W6jTagging.create!(post_id: draft.id, tag_id: ruby.id)
  end

  describe "association scope in the ON clause" do
    it "keeps only rows that match the scope with an inner join" do
      names(W6jAuthor.joins(:published_posts)).should eq(["ann"])
      names(W6jAuthor.joins(:posts)).should eq(["ann", "ann", "bob"])
    end

    it "puts the scope in ON, not WHERE: a left join keeps unmatched parents" do
      relation = W6jAuthor.left_joins(:published_posts)
      names(relation).should eq(["boss", "ann", "bob", "cy"])
      relation.to_sql.should contain(" ON ")
      relation.to_sql.split(" WHERE ").size.should eq(1)
    end

    it "renders the scope once" do
      sql = W6jAuthor.joins(:published_posts).to_sql
      sql.scan("published").size.should eq(1)
    end

    it "supports a scope lambda that takes the relation" do
      names(W6jAuthor.joins(:titled_posts)).should eq(["bob"])
    end

    it "escapes string values written into the ON clause" do
      sql = W6jAuthor.joins(:titled_posts).to_sql
      sql.should contain("'it''s ok'")
    end

    it "combines with where on the joined table and a count" do
      relation = W6jAuthor.joins(:published_posts).where("w6j_posts.title": "ann live")
      names(relation).should eq(["ann"])
      relation.count.should eq(1)
    end

    it "applies the scope declared on a through association to the target table" do
      names(W6jAuthor.joins(:approved_post_comments).distinct).should eq(["ann", "bob"])
      sql = W6jAuthor.joins(:approved_post_comments).to_sql
      sql.should contain("INNER JOIN w6j_posts")
      sql.scan("approved").size.should eq(1)
    end

    it "applies the scope of the association a through goes through" do
      # visible_tags goes through published_posts: only the live post counts.
      names(W6jAuthor.joins(:visible_tags)).should eq(["ann"])
      W6jAuthor.joins(:visible_tags).count.should eq(1)
    end

    it "applies the scope on a nested join" do
      names(W6jAuthor.joins(published_posts: :comments)).should eq(["ann"])
      names(W6jAuthor.joins(posts: :comments).distinct).should eq(["ann", "bob"])
    end

    it "keeps eager_load working with a scoped association" do
      loaded = W6jAuthor.eager_load(:published_posts).order(:id).select
      loaded.map(&.published_posts.size).should eq([0, 1, 0, 0])
    end
  end

  describe "automatic table aliasing" do
    it "aliases a table reached through two different paths" do
      relation = W6jAuthor.joins(:comments, posts: :comments)
      sql = relation.to_sql
      sql.should contain("w6j_comments AS comments_w6j_posts")
      # The alias, not the table, joins the second path to posts.
      sql.should contain("comments_w6j_posts.post_id = w6j_posts.id")
      sql.should contain("w6j_comments.author_id = w6j_authors.id")
      relation.select.size.should be > 0
    end

    it "lets the alias qualify where conditions" do
      relation = W6jAuthor.joins(:comments, posts: :comments).where("comments_w6j_posts.body": "on live, approved").where("w6j_comments.body": "on draft, pending")
      names(relation).should eq(["ann"])
    end

    it "does not alias a clause it already holds" do
      relation = W6jAuthor.joins(:posts).joins(posts: :comments).joins(:posts)
      sql = relation.to_sql
      sql.scan("JOIN w6j_posts").size.should eq(1)
      sql.should_not contain(" AS ")
    end

    it "does not alias the same alias path twice" do
      relation = W6jAuthor.joins(:comments, posts: :comments).joins(posts: :comments)
      relation.to_sql.scan("comments_w6j_posts").size.should eq(2)
    end

    it "aliases a self-referential association automatically" do
      relation = W6jAuthor.joins(:manager)
      relation.to_sql.should contain("w6j_authors AS managers_w6j_authors")
      names(relation).should eq(["ann", "bob"])
      names(relation.where("managers_w6j_authors.name": "boss")).should eq(["ann", "bob"])
      names(relation.where("managers_w6j_authors.name": "nobody")).should eq([] of String)
    end

    it "left-joins a self-referential association" do
      names(W6jAuthor.left_joins(:manager).where("managers_w6j_authors.id": nil)).should eq(["boss", "cy"])
    end

    it "still honors an explicit alias" do
      names(W6jAuthor.joins(:manager, as: "bosses").where("bosses.name": "boss")).should eq(["ann", "bob"])
    end
  end

  describe "raw fragments with binds" do
    it "writes quoted values for ? placeholders" do
      relation = W6jAuthor.joins("INNER JOIN w6j_posts ON w6j_posts.author_id = w6j_authors.id AND w6j_posts.title = ?", "ann live")
      names(relation).should eq(["ann"])
      relation.to_sql.should contain("'ann live'")
    end

    it "takes an array of binds and escapes quotes" do
      relation = W6jAuthor.joins("INNER JOIN w6j_posts ON w6j_posts.author_id = w6j_authors.id AND w6j_posts.title = ? AND w6j_posts.published = ?", ["it's ok", false])
      names(relation).should eq(["bob"])
    end

    it "rejects a mismatched number of binds" do
      expect_raises(ArgumentError) { W6jAuthor.joins("INNER JOIN w6j_posts ON w6j_posts.author_id = ?", 1, 2) }
    end
  end

  describe "polymorphic belongs_to" do
    it "is rejected, like ActiveRecord, because it has no single target table" do
      expect_raises(ArgumentError, /polymorphic/) { W6jComment.joins(:target) }
    end
  end
end
