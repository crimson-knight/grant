require "../../spec_helper"
require "../../support/where_family_models"

private def author_names(relation : Grant::Query::Builder(WfAuthor)) : Array(String)
  relation.order(:id).select.map(&.name.to_s)
end

private def post_titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map(&.title.to_s)
end

describe "where.associated and where.missing" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    ann = WfAuthor.create!(name: "ann", active: true)
    WfAuthor.create!(name: "bob", active: true)

    first = WfPost.create!(title: "first", published: true, score: 1, author_id: ann.id)
    second = WfPost.create!(title: "second", published: true, score: 2, author_id: ann.id)
    WfPost.create!(title: "third", published: false, score: 3)

    # The video shares the first post's id, so a comment lookup that ignored
    # the type column would attach it to `first` as well.
    video = WfVideo.new(title: "clip")
    video.id = first.id
    video.save!
    WfComment.create!(body: "on the second post", commentable_id: second.id, commentable_type: "WfPost")
    WfComment.create!(body: "on the video", commentable_id: video.id, commentable_type: "WfVideo")

    ruby = WfTag.create!(label: "ruby")
    WfTag.create!(label: "unused")
    WfTagging.create!(post_id: first.id, tag_id: ruby.id)
    WfTagging.create!(post_id: first.id, tag_id: ruby.id)
  end

  describe "has_many" do
    it "associated keeps parents with children, once each" do
      relation = WfAuthor.where.associated(:posts)
      author_names(relation).should eq(["ann"])
      relation.count.should eq(1)
    end

    it "missing keeps parents without children" do
      author_names(WfAuthor.where.missing(:posts)).should eq(["bob"])
    end

    it "uses EXISTS / NOT EXISTS instead of joins and DISTINCT" do
      associated_sql = WfAuthor.where.associated(:posts).to_sql
      associated_sql.should contain("EXISTS (SELECT 1 FROM")
      associated_sql.should_not contain("JOIN")
      associated_sql.should_not contain("DISTINCT")
      WfAuthor.where.missing(:posts).to_sql.should contain("NOT EXISTS (SELECT 1 FROM")
    end

    it "keeps the relation chainable and countable" do
      WfAuthor.where.missing(:posts).where(active: true).count.should eq(1)
      WfAuthor.where(name: "ann").where.missing(:posts).count.should eq(0)
    end

    it "keeps has as an alias for associated" do
      author_names(WfAuthor.where.has(:posts)).should eq(["ann"])
    end
  end

  describe "belongs_to" do
    it "associated keeps rows whose parent exists" do
      post_titles(WfPost.where.associated(:author)).should eq(["first", "second"])
    end

    it "missing keeps rows with no parent" do
      post_titles(WfPost.where.missing(:author)).should eq(["third"])
    end

    it "treats a dangling foreign key as missing" do
      WfPost.create!(title: "orphan", published: true, score: 4, author_id: 999_999_i64)
      post_titles(WfPost.where.missing(:author)).should eq(["third", "orphan"])
    end
  end

  describe "through" do
    it "associated finds records reachable through the join model" do
      relation = WfPost.where.associated(:tags)
      post_titles(relation).should eq(["first"])
      relation.count.should eq(1)
    end

    it "missing finds records with no path through the join model" do
      post_titles(WfPost.where.missing(:tags)).should eq(["second", "third"])
    end
  end

  describe "polymorphic" do
    it "matches the type column of a has_many as:" do
      post_titles(WfPost.where.associated(:comments)).should eq(["second"])
      post_titles(WfPost.where.missing(:comments)).should eq(["first", "third"])
    end

    it "matches the other owner type too" do
      WfVideo.where.associated(:comments).count.should eq(1)
      WfVideo.where.missing(:comments).count.should eq(0)
    end

    it "rejects a polymorphic belongs_to, which has no single target table" do
      expect_raises(ArgumentError, /polymorphic/) { WfComment.where.associated(:commentable) }
    end
  end

  describe "several names and other clauses" do
    it "requires every name for associated" do
      post_titles(WfPost.where.associated(:comments, :author)).should eq(["second"])
      post_titles(WfPost.where.associated(:tags, :author)).should eq(["first"])
    end

    it "requires none of the names for missing" do
      post_titles(WfPost.where.missing(:comments, :tags)).should eq(["third"])
    end

    it "binds values in order around the subquery" do
      relation = WfPost.where(published: true).where.associated(:comments).where(score: 2)
      post_titles(relation).should eq(["second"])
      relation = WfPost.where(title: "second").where.missing(:tags).where(score: 2).where(published: true)
      post_titles(relation).should eq(["second"])
    end

    it "composes with or" do
      relation = WfPost.where.associated(:tags).or(WfPost.where(title: "third"))
      post_titles(relation).should eq(["first", "third"])
    end
  end

  describe "errors" do
    it "raises an AssociationNotFoundError for an unknown name" do
      expect_raises(Grant::AssociationNotFoundError) { WfAuthor.where.associated(:nonsense) }
      expect_raises(Grant::AssociationNotFoundError) { WfAuthor.where.missing(:nonsense) }
    end
  end
end
