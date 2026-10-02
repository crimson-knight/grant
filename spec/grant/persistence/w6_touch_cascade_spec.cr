require "../../spec_helper"
require "../../support/composite_sql_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6TouchBlog < Grant::Base
    connection {{ adapter_literal }}
    table w6_touch_blogs

    column id : Int64, primary: true
    column name : String?
    timestamps
  end

  class W6TouchPost < Grant::Base
    connection {{ adapter_literal }}
    table w6_touch_posts

    column id : Int64, primary: true
    column w6_touch_blog_id : Int64?
    column title : String?
    column views : Int32?
    timestamps
    belongs_to :w6_touch_blog, class_name: W6TouchBlog, foreign_key: w6_touch_blog_id : Int64?, touch: true, optional: true
  end
{% end %}

W6TouchBlog.migrator.drop_and_create
W6TouchPost.migrator.drop_and_create

private W6_OLD = Time.utc(2001, 1, 1)

describe "touch" do
  before_each do
    W6TouchPost.clear
    W6TouchBlog.clear
  end

  it "cascades to a belongs_to touch: true parent when the child is touched" do
    blog = W6TouchBlog.create!(name: "b")
    post = W6TouchPost.create!(title: "p", w6_touch_blog_id: blog.id)
    W6TouchBlog.where(id: blog.id).update_all({"updated_at" => W6_OLD.as(Grant::Columns::Type)})

    post.touch(time: Time.utc(2030, 1, 1)).should be_true
    W6TouchBlog.find!(blog.id).updated_at.not_nil!.to_utc.should be > W6_OLD
  end

  it "folds increment!(touch: true) into one UPDATE and cascades" do
    blog = W6TouchBlog.create!(name: "b")
    post = W6TouchPost.create!(title: "p", views: 1, w6_touch_blog_id: blog.id)

    statements = capture_statements { post.increment!(:views, 2, touch: true) }
    statements.count(&.match(/\A\s*UPDATE\s+\S*w6_touch_posts/i)).should eq(1)
    W6TouchPost.find!(post.id).views.should eq(3)
  end

  it "touches nothing on a no_touching model" do
    blog = W6TouchBlog.create!(name: "b")
    post = W6TouchPost.create!(title: "p", w6_touch_blog_id: blog.id)
    W6TouchBlog.where(id: blog.id).update_all({"updated_at" => W6_OLD.as(Grant::Columns::Type)})

    W6TouchBlog.no_touching { post.touch }
    W6TouchBlog.find!(blog.id).updated_at.not_nil!.to_utc.should eq(W6_OLD)
  end
end
