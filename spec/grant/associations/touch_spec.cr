require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class TchBlog < Grant::Base
    connection {{ adapter_literal }}
    table tch_blogs
    column id : Int64, primary: true
    column name : String?
    column pinged_at : Time?
    timestamps
  end

  class TchPost < Grant::Base
    connection {{ adapter_literal }}
    table tch_posts
    column id : Int64, primary: true
    column tch_blog_id : Int64?
    column title : String?
    timestamps
    belongs_to :tch_blog, class_name: TchBlog, foreign_key: tch_blog_id : Int64?, touch: true, optional: true
  end

  class TchPin < Grant::Base
    connection {{ adapter_literal }}
    table tch_pins
    column id : Int64, primary: true
    column tch_blog_id : Int64?
    belongs_to :tch_blog, class_name: TchBlog, foreign_key: tch_blog_id : Int64?, touch: :pinged_at, optional: true
  end

  class TchTrunk < Grant::Base
    connection {{ adapter_literal }}
    table tch_trunks
    column id : Int64, primary: true
    column name : String?
    timestamps
  end

  class TchBranch < Grant::Base
    connection {{ adapter_literal }}
    table tch_branches
    column id : Int64, primary: true
    column tch_trunk_id : Int64?
    timestamps
    belongs_to :tch_trunk, class_name: TchTrunk, foreign_key: tch_trunk_id : Int64?, touch: true, optional: true
  end

  class TchLeaf < Grant::Base
    connection {{ adapter_literal }}
    table tch_leaves
    column id : Int64, primary: true
    column tch_branch_id : Int64?
    column shade : String?
    belongs_to :tch_branch, class_name: TchBranch, foreign_key: tch_branch_id : Int64?, touch: true, optional: true
  end
{% end %}

private OLD_TIME = Time.utc(2000, 1, 1)

private def age(model : TchBlog.class, id) : Nil
  model.where(id: id).update_all({"updated_at" => OLD_TIME.as(Grant::Columns::Type)})
end

private def blog_updated_at(id) : Time
  TchBlog.find!(id).updated_at.not_nil!.to_utc
end

describe "belongs_to touch:" do
  before_all do
    TchBlog.migrator.drop_and_create
    TchPost.migrator.drop_and_create
    TchPin.migrator.drop_and_create
    TchTrunk.migrator.drop_and_create
    TchBranch.migrator.drop_and_create
    TchLeaf.migrator.drop_and_create
  end

  before_each do
    TchPost.clear
    TchPin.clear
    TchLeaf.clear
    TchBranch.clear
    TchBlog.clear
    TchTrunk.clear
  end

  it "touches the parent when a child is created" do
    blog = TchBlog.create!(name: "b")
    age(TchBlog, blog.id)

    TchPost.create!(title: "p", tch_blog_id: blog.id)

    blog_updated_at(blog.id).should be > OLD_TIME
  end

  it "touches the parent by key with one UPDATE and never loads it" do
    blog = TchBlog.create!(name: "b")
    post = TchPost.create!(title: "p", tch_blog_id: blog.id)
    age(TchBlog, blog.id)

    post.title = "changed"
    statements = StatementRecorder.statements { post.save.should be_true }

    StatementRecorder.count(statements, "UPDATE", "tch_blogs").should eq(1)
    StatementRecorder.count(statements, "SELECT", "tch_blogs").should eq(0)
    blog_updated_at(blog.id).should be > OLD_TIME
  end

  it "does nothing when the save changed nothing" do
    blog = TchBlog.create!(name: "b")
    post = TchPost.create!(title: "p", tch_blog_id: blog.id)
    age(TchBlog, blog.id)

    statements = StatementRecorder.statements { post.save.should be_true }

    StatementRecorder.count(statements, "UPDATE", "tch_blogs").should eq(0)
    blog_updated_at(blog.id).should eq(OLD_TIME)
  end

  it "touches the old parent as well as the new one when the key changes" do
    old_blog = TchBlog.create!(name: "old")
    new_blog = TchBlog.create!(name: "new")
    post = TchPost.create!(title: "p", tch_blog_id: old_blog.id)
    age(TchBlog, old_blog.id)
    age(TchBlog, new_blog.id)

    post.tch_blog_id = new_blog.id
    post.save.should be_true

    blog_updated_at(old_blog.id).should be > OLD_TIME
    blog_updated_at(new_blog.id).should be > OLD_TIME
  end

  it "touches the parent when a child is destroyed" do
    blog = TchBlog.create!(name: "b")
    post = TchPost.create!(title: "p", tch_blog_id: blog.id)
    age(TchBlog, blog.id)

    post.destroy.should be_true

    blog_updated_at(blog.id).should be > OLD_TIME
  end

  it "touches the named column too" do
    blog = TchBlog.create!(name: "b")
    age(TchBlog, blog.id)

    TchPin.create!(tch_blog_id: blog.id)

    found = TchBlog.find!(blog.id)
    found.pinged_at.should_not be_nil
    found.updated_at.not_nil!.to_utc.should be > OLD_TIME
  end

  it "skips the touch inside no_touching" do
    blog = TchBlog.create!(name: "b")
    age(TchBlog, blog.id)

    TchBlog.no_touching { TchPost.create!(title: "p", tch_blog_id: blog.id) }

    blog_updated_at(blog.id).should eq(OLD_TIME)
  end

  it "does not touch when there is no parent" do
    TchPost.create!(title: "orphan").persisted?.should be_true
  end

  it "cascades through parents that touch their own parent" do
    trunk = TchTrunk.create!(name: "t")
    branch = TchBranch.create!(tch_trunk_id: trunk.id)
    TchTrunk.where(id: trunk.id).update_all({"updated_at" => OLD_TIME.as(Grant::Columns::Type)})
    TchBranch.where(id: branch.id).update_all({"updated_at" => OLD_TIME.as(Grant::Columns::Type)})

    TchLeaf.create!(tch_branch_id: branch.id, shade: "green")

    TchBranch.find!(branch.id).updated_at.not_nil!.to_utc.should be > OLD_TIME
    TchTrunk.find!(trunk.id).updated_at.not_nil!.to_utc.should be > OLD_TIME
  end

  describe "Model.touch_all" do
    it "touches many parents by key with one UPDATE" do
      blogs = 3.times.map { |i| TchBlog.create!(name: "b#{i}") }.to_a
      blogs.each { |blog| age(TchBlog, blog.id) }

      statements = StatementRecorder.statements do
        TchBlog.where(id: blogs.map(&.id)).touch_all.should eq(3)
      end

      StatementRecorder.count(statements, "UPDATE", "tch_blogs").should eq(1)
      StatementRecorder.count(statements, "SELECT").should eq(0)
      blogs.each { |blog| blog_updated_at(blog.id).should be > OLD_TIME }
    end
  end
end
