require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class JnUser < Grant::Base
    connection {{ adapter_literal }}
    table jn_users
    column id : Int64, primary: true
    column name : String
    has_many :posts, class_name: JnPost, foreign_key: :jn_user_id
  end

  class JnPost < Grant::Base
    connection {{ adapter_literal }}
    table jn_posts
    column id : Int64, primary: true
    column title : String
    column jn_user_id : Int64?
    belongs_to :jn_user, class_name: JnUser, foreign_key: :jn_user_id, optional: true
    has_many :comments, class_name: JnComment, foreign_key: :jn_post_id
  end

  class JnComment < Grant::Base
    connection {{ adapter_literal }}
    table jn_comments
    column id : Int64, primary: true
    column body : String
    column jn_post_id : Int64?
    belongs_to :jn_post, class_name: JnPost, foreign_key: :jn_post_id, optional: true
  end

  class JnEmployee < Grant::Base
    connection {{ adapter_literal }}
    table jn_employees
    column id : Int64, primary: true
    column name : String
    column jn_manager_id : Int64?
    belongs_to :jn_manager, class_name: JnEmployee, foreign_key: :jn_manager_id, optional: true
  end
{% end %}

def seed_blog
  ada = JnUser.create!(name: "Ada")
  grace = JnUser.create!(name: "Grace")
  JnUser.create!(name: "Nobody")
  first = JnPost.create!(title: "First", jn_user_id: ada.id)
  JnPost.create!(title: "Second", jn_user_id: ada.id)
  other = JnPost.create!(title: "Other", jn_user_id: grace.id)
  JnComment.create!(body: "nice", jn_post_id: first.id)
  JnComment.create!(body: "agreed", jn_post_id: first.id)
  JnComment.create!(body: "hm", jn_post_id: other.id)
end

describe "joins: nested, raw fragments, aliases and de-duplication" do
  before_all do
    JnUser.migrator.drop_and_create
    JnPost.migrator.drop_and_create
    JnComment.migrator.drop_and_create
    JnEmployee.migrator.drop_and_create
  end

  before_each do
    JnComment.clear
    JnPost.clear
    JnUser.clear
    JnEmployee.clear
  end

  describe "nested association joins" do
    it "joins each level from the model the previous level reached" do
      sql = JnUser.joins(posts: :comments).raw_sql
      sql.should contain("INNER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id")
      sql.should contain("INNER JOIN jn_comments ON jn_comments.jn_post_id = jn_posts.id")
      sql.index!("jn_posts ON").should be < sql.index!("jn_comments ON")
    end

    it "filters through the nested table" do
      seed_blog
      names = JnUser.joins(posts: :comments).where("jn_comments.body": "hm").select.map(&.name)
      names.should eq(["Grace"])
    end

    it "multiplies parent rows for a has_many chain and distinct collapses them" do
      seed_blog
      JnUser.joins(posts: :comments).select.size.should eq(3)
      JnUser.joins(posts: :comments).distinct.select.map(&.name).sort!.should eq(["Ada", "Grace"])
    end

    it "accepts arrays and several branches" do
      sql = JnUser.joins(posts: [:comments, :jn_user]).raw_sql
      sql.should contain("jn_comments ON")
      sql.scan("INNER JOIN jn_users").size.should eq(1)
    end

    it "raises for an unknown association at any level" do
      expect_raises(ArgumentError, /Unknown association :nope/) { JnUser.joins(posts: :nope) }
      expect_raises(ArgumentError, /Unknown association :nope/) { JnUser.joins(nope: :comments) }
    end

    it "resolves nested left joins" do
      seed_blog
      names = JnUser.left_joins(posts: :comments).where("jn_comments.id IS NULL").select.map(&.name).sort!
      names.should eq(["Ada", "Nobody"])
    end
  end

  describe "raw fragments" do
    it "emits the fragment as written" do
      seed_blog
      relation = JnUser.joins("INNER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id AND jn_posts.title = 'Other'")
      relation.raw_sql.should contain("INNER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id AND jn_posts.title = 'Other'")
      relation.select.map(&.name).should eq(["Grace"])
    end

    it "supports a LEFT OUTER fragment through left_joins" do
      seed_blog
      names = JnUser.left_joins("LEFT OUTER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id")
        .where("jn_posts.id IS NULL").select.map(&.name)
      names.should eq(["Nobody"])
    end

    it "lets where, order and aggregates qualify columns with the tables a fragment joins" do
      seed_blog
      relation = JnUser.joins("INNER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id")
      relation.where("jn_posts.title": "Other").select.map(&.name).should eq(["Grace"])
      relation.order("jn_posts.title", :desc).select.map(&.name).should eq(["Ada", "Grace", "Ada"])
      relation.count("jn_posts.id").should eq(3_i64)

      aliased = JnUser.joins("LEFT JOIN jn_posts AS p ON p.jn_user_id = jn_users.id INNER JOIN jn_comments c ON c.jn_post_id = p.id")
      aliased.where("c.body": "hm").select.map(&.name).should eq(["Grace"])
      aliased.where("p.title": "First").distinct.select.map(&.name).should eq(["Ada"])
    end

    it "refuses fragments that could carry another statement" do
      expect_raises(ArgumentError, /statement separator/) { JnUser.joins("INNER JOIN jn_posts ON 1=1; DROP TABLE jn_users") }
      expect_raises(ArgumentError, /comment marker/) { JnUser.joins("INNER JOIN jn_posts ON 1=1 -- x") }
      expect_raises(ArgumentError, /blank/) { JnUser.joins("  ") }
    end

    it "does not change the receiver" do
      base = JnUser.where(name: "Ada")
      base.joins("INNER JOIN jn_posts ON jn_posts.jn_user_id = jn_users.id")
      base.join_clauses.should be_empty
    end
  end

  describe "self-join alias" do
    it "joins a table to itself under an alias" do
      boss = JnEmployee.create!(name: "Boss")
      JnEmployee.create!(name: "Ann", jn_manager_id: boss.id)
      JnEmployee.create!(name: "Bob", jn_manager_id: boss.id)
      JnEmployee.create!(name: "Loner")

      relation = JnEmployee.joins(:jn_manager, as: "managers").where("managers.name": "Boss").order(:name)
      relation.raw_sql.should contain("INNER JOIN jn_employees AS managers ON managers.id = jn_employees.jn_manager_id")
      relation.select.map(&.name).should eq(["Ann", "Bob"])
    end

    it "supports a left alias and pluck across the alias" do
      boss = JnEmployee.create!(name: "Boss")
      JnEmployee.create!(name: "Ann", jn_manager_id: boss.id)
      JnEmployee.create!(name: "Loner")

      rows = JnEmployee.left_outer_joins(:jn_manager, as: "managers").order(:name).pluck("jn_employees.name", "managers.name")
      rows.should eq([["Ann", "Boss"], ["Boss", nil], ["Loner", nil]])
    end

    it "rejects an alias that is not an identifier" do
      expect_raises(ArgumentError, /alias must be an identifier/) { JnEmployee.joins(:jn_manager, as: "m; DROP") }
    end
  end

  describe "de-duplication" do
    it "joins an association once when it is requested through different paths" do
      once = JnUser.joins(:posts).joins(posts: :comments).raw_sql
      once.scan("INNER JOIN jn_posts").size.should eq(1)
      once.scan("INNER JOIN jn_comments").size.should eq(1)
    end

    it "joins once when the same call repeats" do
      JnUser.joins(:posts).joins(:posts).join_clauses.size.should eq(1)
      JnUser.joins("jn_posts", on: "jn_posts.jn_user_id = jn_users.id")
        .joins("jn_posts", on: "jn_posts.jn_user_id = jn_users.id").join_clauses.size.should eq(1)
    end

    it "keeps a relation working after a merge that repeats a join" do
      seed_blog
      merged = JnUser.joins(:posts).merge(JnUser.joins(:posts).where(name: "Ada"))
      merged.join_clauses.size.should eq(1)
      merged.select.map(&.name).uniq!.should eq(["Ada"])
    end
  end
end
