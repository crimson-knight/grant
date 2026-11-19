require "../../spec_helper"

# Issue #74: a `class_name:` path is resolved in the declaring model's own
# namespace, the way Crystal resolves it in the model body, wherever Grant reads
# the association (eager loading, preloading, `through`, association scopes).
#
# `spec/spec_models.cr` defines a top-level `::Comment` and `::Article`, so inside
# `Admin::Post` the bare names `Comment` and `Article` have two candidates; the
# model means `Admin::Comment` and `Admin::Article`. Both are defined after
# `Admin::Post`, so its associations are forward references, as in an app whose
# `src/models/*.cr` files are required in alphabetical order.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  module Admin
    class Post < Grant::Base
      connection {{ adapter_literal }}
      table admin_posts

      column id : Int64, primary: true
      column title_text : String

      has_many :comments, class_name: Comment
      has_many :flagged_comments, -> { where(flagged: true) }, class_name: Comment, foreign_key: :post_id
      has_many :articles, class_name: Article, through: :comments
    end

    class Comment < Grant::Base
      connection {{ adapter_literal }}
      table admin_comments

      column id : Int64, primary: true
      column body_text : String
      column flagged : Bool = false

      belongs_to :post, class_name: Post
      belongs_to :article, class_name: Article
    end

    class Article < Grant::Base
      connection {{ adapter_literal }}
      table admin_articles

      column id : Int64, primary: true
      column headline_text : String
    end
  end

  # Reopening a model and declaring an association again still compiles, and
  # the redeclared association keeps its namespaced target.
  class Admin::Post < Grant::Base
    has_many :comments, class_name: Comment

    # `::Comment` and `Comment` are different targets here; the redeclaration
    # (Admin::Comment) is the one that holds.
    has_many :thread_comments, class_name: ::Comment, foreign_key: :post_id
    has_many :thread_comments, class_name: Comment, foreign_key: :post_id

    # A nested type that already holds the next alias name is skipped over.
    # (Escaped so it is evaluated here, after the declarations above took theirs.)
    \{% begin %}
      class GrantAssociationTarget\{{ Grant::Associations::TARGET_ALIAS_SEQUENCE.size + 1 }}
      end
    \{% end %}
    has_many :guarded_comments, class_name: Comment, foreign_key: :post_id
  end
{% end %}

private def create_admin_post_with_comments : Admin::Post
  post = Admin::Post.create!(title_text: "release notes")
  article = Admin::Article.create!(headline_text: "v2 ships")
  Admin::Comment.create!(body_text: "plain", flagged: false, post_id: post.id, article_id: article.id)
  Admin::Comment.create!(body_text: "flagged", flagged: true, post_id: post.id, article_id: article.id)
  post
end

describe "Association targets named by class_name:" do
  before_all do
    Admin::Post.migrator.drop_and_create
    Admin::Comment.migrator.drop_and_create
    Admin::Article.migrator.drop_and_create
  end

  before_each do
    Admin::Comment.clear
    Admin::Article.clear
    Admin::Post.clear
  end

  describe "in a namespaced model" do
    it "eager-loads a has_many target from the model's own namespace" do
      create_admin_post_with_comments

      post = Admin::Post.includes(:comments).to_a.first
      comments = post.comments.to_a
      comments.map(&.class).uniq!.should eq([Admin::Comment])
      comments.map(&.body_text).sort!.should eq(["flagged", "plain"])
    end

    it "eager-loads a belongs_to target from the model's own namespace" do
      create_admin_post_with_comments

      comment = Admin::Comment.includes(:post).to_a.first
      comment.post.should be_a(Admin::Post)
    end

    it "eager-loads a has_many through whose target is in the model's own namespace" do
      create_admin_post_with_comments

      post = Admin::Post.includes(:articles).to_a.first
      post.articles.to_a.map(&.headline_text).uniq!.should eq(["v2 ships"])
      post.articles.to_a.first.should be_a(Admin::Article)
    end

    it "preloads records already in memory from the model's own namespace" do
      create_admin_post_with_comments

      posts = Admin::Post.all.to_a
      Grant::Preloader.new(posts, :comments).call
      posts.first.comments.to_a.map(&.class).uniq!.should eq([Admin::Comment])
    end

    it "eager-loads the target of the latest declaration of a redeclared association" do
      create_admin_post_with_comments

      post = Admin::Post.includes(:thread_comments).to_a.first
      post.thread_comments.to_a.map(&.class).uniq!.should eq([Admin::Comment])
    end

    it "skips an alias name the model already uses for its own type" do
      create_admin_post_with_comments

      post = Admin::Post.includes(:guarded_comments).to_a.first
      post.guarded_comments.to_a.map(&.class).uniq!.should eq([Admin::Comment])
    end

    it "applies an association scope to the target from the model's own namespace" do
      create_admin_post_with_comments

      post = Admin::Post.includes(:flagged_comments).to_a.first
      post.flagged_comments.to_a.map(&.body_text).should eq(["flagged"])
    end
  end
end
