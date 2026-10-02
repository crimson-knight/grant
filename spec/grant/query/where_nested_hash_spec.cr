require "../../spec_helper"
require "../../support/where_family_models"

private def post_titles(relation : Grant::Query::Builder(WfPost)) : Array(String)
  relation.order(:id).select.map(&.title.to_s)
end

private def comment_bodies(relation : Grant::Query::Builder(WfComment)) : Array(String)
  relation.order(:id).select.map(&.body.to_s)
end

describe "where with a nested table hash and record values" do
  before_all { wf_create_tables }
  before_each do
    wf_clear_tables
    ann = WfAuthor.create!(name: "ann", active: true)
    bob = WfAuthor.create!(name: "bob", active: false)
    cy = WfAuthor.create!(name: "cy", active: true)

    WfPost.create!(title: "by ann", published: true, score: 1, author_id: ann.id)
    WfPost.create!(title: "by bob", published: false, score: 2, author_id: bob.id)
    WfPost.create!(title: "by cy", published: true, score: 3, author_id: cy.id)
    WfPost.create!(title: "anonymous", published: true, score: 4)
  end

  describe "joined table hash" do
    it "filters on the joined table's columns" do
      relation = WfPost.joins(:author).where(wf_authors: {active: true})
      post_titles(relation).should eq(["by ann", "by cy"])
    end

    it "accepts the association name as the key" do
      post_titles(WfPost.joins(:author).where(author: {name: "bob"})).should eq(["by bob"])
      post_titles(WfPost.joins(:author).where(author: {name: ["ann", "cy"]})).should eq(["by ann", "by cy"])
    end

    it "mixes joined and own columns" do
      relation = WfPost.joins(:author).where(published: true, wf_authors: {active: true, name: "cy"})
      post_titles(relation).should eq(["by cy"])
    end

    it "supports ranges, nil and enums like a flat hash" do
      post_titles(WfPost.joins(:author).where(wf_authors: {id: 1_i64..})).size.should eq(3)
      post_titles(WfPost.joins(:author).where(wf_authors: {name: nil})).should eq([] of String)
    end

    it "accepts the model's own table" do
      post_titles(WfPost.where(wf_posts: {published: false})).should eq(["by bob"])
    end

    it "works under or" do
      relation = WfPost.joins(:author).where(title: "anonymous").or(wf_authors: {name: "bob"})
      post_titles(relation).should eq(["by bob"])
    end

    it "rejects an unknown table" do
      expect_raises(ArgumentError, /Unknown table/) { WfPost.where(secrets: {name: "x"}) }
    end

    it "rejects an unknown column on a known table" do
      expect_raises(ArgumentError, /Unknown query field/) do
        WfPost.joins(:author).where(wf_authors: {nonsense: 1}).to_sql
      end
    end

    it "rejects an identifier that is not a plain name" do
      expect_raises(ArgumentError) do
        WfPost.joins(:author).where(wf_authors: {"name = 1 OR 1=1 OR x": 1}).to_sql
      end
    end

    it "requires the table to be joined by the time the SQL is built" do
      expect_raises(ArgumentError, /Unknown query table|Unknown query field/) do
        WfPost.where(wf_authors: {active: true}).to_sql
      end
    end
  end

  describe "where(association: record)" do
    it "matches the foreign key of one record" do
      ann = WfAuthor.find_by!(name: "ann")
      post_titles(WfPost.where(author: ann)).should eq(["by ann"])
      WfPost.where(author: ann).to_sql.should contain("author_id")
    end

    it "matches an array of records with IN" do
      authors = WfAuthor.where(name: ["ann", "cy"]).order(:id).select
      post_titles(WfPost.where(author: authors)).should eq(["by ann", "by cy"])
      relation = WfPost.where(author: authors)
      relation.to_sql.should contain("IN")
    end

    it "matches nil as an absent parent" do
      post_titles(WfPost.where(author: nil)).should eq(["anonymous"])
    end

    it "accepts a bare key" do
      ann = WfAuthor.find_by!(name: "ann")
      post_titles(WfPost.where(author: ann.id)).should eq(["by ann"])
      post_titles(WfPost.where(author: [ann.id, nil])).should eq(["by ann", "anonymous"])
    end

    it "matches an empty array to nothing" do
      post_titles(WfPost.where(author: [] of WfAuthor)).should eq([] of String)
    end

    it "works with where.not, or and rewhere" do
      ann = WfAuthor.find_by!(name: "ann")
      bob = WfAuthor.find_by!(name: "bob")
      post_titles(WfPost.where.not(author: ann, published: false)).should eq(["by ann", "by bob", "by cy", "anonymous"])
      post_titles(WfPost.where(author: ann).or(author: bob)).should eq(["by ann", "by bob"])
      post_titles(WfPost.where(author: ann).rewhere(author: bob)).should eq(["by bob"])
    end

    it "does not load or query the records it is given" do
      ann = WfAuthor.find_by!(name: "ann")
      # The relation is built from the record's key alone.
      relation = WfPost.where(author: ann)
      relation.to_sql.should_not contain("wf_authors")
    end
  end

  describe "polymorphic belongs_to" do
    it "matches the id and the type column" do
      post = WfPost.find_by!(title: "by ann")
      video = WfVideo.create!(title: "clip")
      WfComment.create!(body: "on post", commentable_id: post.id, commentable_type: "WfPost")
      WfComment.create!(body: "on video", commentable_id: video.id, commentable_type: "WfVideo")

      comment_bodies(WfComment.where(commentable: post)).should eq(["on post"])
      comment_bodies(WfComment.where(commentable: video)).should eq(["on video"])
      WfComment.where(commentable: post).to_sql.should contain("commentable_type")
    end

    it "keeps records of different types apart even when their ids collide" do
      post = WfPost.find_by!(title: "by ann")
      WfVideo.clear
      video = WfVideo.new(title: "clip")
      video.id = post.id
      video.save!
      video.id.should eq(post.id)
      WfComment.create!(body: "on post", commentable_id: post.id, commentable_type: "WfPost")
      WfComment.create!(body: "on video", commentable_id: video.id, commentable_type: "WfVideo")

      comment_bodies(WfComment.where(commentable: video)).should eq(["on video"])
      comment_bodies(WfComment.where(commentable: post)).should eq(["on post"])
    end

    it "handles an array of mixed types" do
      post = WfPost.find_by!(title: "by ann")
      other_post = WfPost.find_by!(title: "by bob")
      video = WfVideo.create!(title: "clip")
      WfComment.create!(body: "on post", commentable_id: post.id, commentable_type: "WfPost")
      WfComment.create!(body: "on other post", commentable_id: other_post.id, commentable_type: "WfPost")
      WfComment.create!(body: "on video", commentable_id: video.id, commentable_type: "WfVideo")
      WfComment.create!(body: "loose")

      mixed = [post.as(Grant::Base), video.as(Grant::Base)]
      comment_bodies(WfComment.where(commentable: mixed)).should eq(["on post", "on video"])
      comment_bodies(WfComment.where(commentable: [post, other_post])).should eq(["on post", "on other post"])
    end

    it "matches nil to a missing target" do
      WfComment.create!(body: "loose")
      post = WfPost.find_by!(title: "by ann")
      WfComment.create!(body: "on post", commentable_id: post.id, commentable_type: "WfPost")
      comment_bodies(WfComment.where(commentable: nil)).should eq(["loose"])
    end

    it "requires records, not bare keys, so the type can be matched" do
      expect_raises(ArgumentError, /polymorphic/) { WfComment.where(commentable: [1_i64, 2_i64]).to_sql }
    end
  end

  describe "errors" do
    it "rejects a record under a name that is not an association" do
      ann = WfAuthor.find_by!(name: "ann")
      expect_raises(ArgumentError, /not an association/) { WfPost.where(nonsense: ann) }
    end
  end

  describe "attributes hash typed as Grant::Columns::Type" do
    it "reads an array value as an IN list, as where(**args) does" do
      scores = [1, 3].as(Grant::Columns::Type)
      matches = {"score" => scores} of String => Grant::Columns::Type
      post_titles(WfPost.where(matches)).should eq(["by ann", "by cy"])
      post_titles(WfPost.where(title: "by bob").or(matches)).should eq(["by ann", "by bob", "by cy"])
    end
  end
end
