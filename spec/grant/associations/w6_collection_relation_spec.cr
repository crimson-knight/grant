require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6rUser < Grant::Base
    connection {{ adapter_literal }}
    table w6r_users
    column id : Int64, primary: true
    column name : String?
    has_many :w6r_posts, class_name: W6rPost, foreign_key: :w6r_user_id
    has_many :w6r_published_posts, -> { where(active: true) }, class_name: W6rPost, foreign_key: :w6r_user_id
    has_many :w6r_links, class_name: W6rLink, foreign_key: :w6r_user_id
    has_many :w6r_tags, class_name: W6rTag, through: :w6r_links
  end

  class W6rPost < Grant::Base
    connection {{ adapter_literal }}
    table w6r_posts
    column id : Int64, primary: true
    column title : String?
    column score : Int32?
    column active : Bool?
    column w6r_user_id : Int64?
    belongs_to :w6r_user, class_name: W6rUser, foreign_key: :w6r_user_id, optional: true
  end

  class W6rTag < Grant::Base
    connection {{ adapter_literal }}
    table w6r_tags
    column id : Int64, primary: true
    column label : String?
  end

  class W6rLink < Grant::Base
    connection {{ adapter_literal }}
    table w6r_links
    column id : Int64, primary: true
    column w6r_user_id : Int64?
    column w6r_tag_id : Int64?
    belongs_to :w6r_user, class_name: W6rUser, foreign_key: :w6r_user_id, optional: true
    belongs_to :w6r_tag, class_name: W6rTag, foreign_key: :w6r_tag_id, optional: true
  end
{% end %}

private def w6r_selects(statements : Array(String)) : Array(String)
  statements.select(&.lstrip.upcase.starts_with?("SELECT"))
end

private def w6r_fixture : {W6rUser, W6rUser}
  user = W6rUser.create!(name: "u")
  other = W6rUser.create!(name: "o")
  [{"a", 3, true}, {"b", 1, true}, {"c", 2, false}, {"d", 5, true}].each do |title, score, active|
    W6rPost.create!(title: title, score: score, active: active, w6r_user_id: user.id)
  end
  W6rPost.create!(title: "z", score: 100, active: true, w6r_user_id: other.id)
  {user, other}
end

describe "association collection as a chainable relation" do
  before_all do
    W6rUser.migrator.drop_and_create
    W6rPost.migrator.drop_and_create
    W6rTag.migrator.drop_and_create
    W6rLink.migrator.drop_and_create
  end

  before_each do
    W6rLink.clear
    W6rTag.clear
    W6rPost.clear
    W6rUser.clear
  end

  it "orders and limits in SQL without loading the association" do
    user, _ = w6r_fixture
    collection = user.w6r_posts
    titles = [] of String?
    statements = StatementRecorder.statements do
      titles = collection.order(score: :desc).limit(2).map(&.title)
    end

    titles.should eq(["d", "a"])
    selects = w6r_selects(statements)
    selects.size.should eq(1)
    selects.first.upcase.should contain("ORDER BY")
    selects.first.upcase.should contain("LIMIT 2")
    collection.loaded?.should be_false
  end

  it "applies offset, reorder and reverse_order" do
    user, _ = w6r_fixture

    user.w6r_posts.order(score: :asc).offset(1).limit(2).map(&.title).should eq(["c", "a"])
    user.w6r_posts.order(score: :asc).reorder(score: :desc).first.not_nil!.title.should eq("d")
    user.w6r_posts.order(score: :asc).reverse_order.first.not_nil!.title.should eq("d")
  end

  it "plucks only the requested columns" do
    user, _ = w6r_fixture
    values = [] of Array(Grant::Columns::Type)
    statements = StatementRecorder.statements do
      values = user.w6r_posts.order(:score).pluck(:title, :score)
    end

    values.map { |row| {row[0], row[1].to_s} }.should eq([{"b", "1"}, {"c", "2"}, {"a", "3"}, {"d", "5"}])
    selects = w6r_selects(statements)
    selects.size.should eq(1)
    selects.first.should_not contain("active")
  end

  it "aggregates in SQL" do
    user, _ = w6r_fixture
    sum = nil
    statements = StatementRecorder.statements do
      sum = user.w6r_posts.sum(:score)
    end

    sum.to_s.should eq("11")
    w6r_selects(statements).first.upcase.should contain("SUM(")
    user.w6r_posts.sum(:score, as: Int64).should eq(11_i64)
    user.w6r_posts.minimum(:score).to_s.should eq("1")
    user.w6r_posts.maximum(:score).to_s.should eq("5")
    user.w6r_posts.average(:score).to_s.to_f.should eq(2.75)
  end

  it "answers distinct and group in SQL" do
    user, _ = w6r_fixture
    W6rPost.create!(title: "a", score: 9, active: false, w6r_user_id: user.id)

    user.w6r_posts.select(:title).distinct.count.should eq(4)
    grouped = user.w6r_posts.group(:active).count
    grouped.is_a?(Int64).should be_false
    (grouped.is_a?(Hash) ? grouped.size : 0).should eq(2)
  end

  it "iterates in batches with find_each and in_batches" do
    user, _ = w6r_fixture
    seen = [] of String?
    statements = StatementRecorder.statements do
      user.w6r_posts.find_each(batch_size: 2) { |post| seen << post.title }
    end

    seen.compact.sort!.should eq(["a", "b", "c", "d"])
    w6r_selects(statements).size.should be >= 2

    sizes = [] of Int32
    user.w6r_posts.in_batches(of: 3, load: true) { |batch| sizes << batch.select.size }
    sizes.sum.should eq(4)

    batches = [] of Int32
    user.w6r_posts.find_in_batches(batch_size: 3) { |batch| batches << batch.size }
    batches.should eq([3, 1])
  end

  it "joins and preloads from the owner scope" do
    user, _ = w6r_fixture

    user.w6r_posts.joins(:w6r_user).count.should eq(4)
    posts = user.w6r_posts.includes(:w6r_user).select
    posts.size.should eq(4)
    posts.first.w6r_user!.id.should eq(user.id)
  end

  it "chains where, not and the where chain onto the owner scope" do
    user, _ = w6r_fixture

    user.w6r_posts.where(active: true).order(:score).map(&.title).should eq(["b", "a", "d"])
    user.w6r_posts.where("score > ?", 2).count.should eq(2)
    user.w6r_posts.where(:score, :gt, 2).count.should eq(2)
    user.w6r_posts.where.not(:score, 2).count.should eq(3)
  end

  it "keeps the association scope when chaining" do
    user, _ = w6r_fixture

    user.w6r_published_posts.order(score: :desc).pluck(:title).map(&.first).should eq(["d", "a", "b"])
    user.w6r_published_posts.sum(:score).to_s.should eq("9")
  end

  it "works on a has_many :through collection" do
    user, _ = w6r_fixture
    other_tag = W6rTag.create!(label: "x")
    tags = ["t1", "t2", "t3"].map { |label| W6rTag.create!(label: label) }
    tags.each { |tag| W6rLink.create!(w6r_user_id: user.id, w6r_tag_id: tag.id) }
    W6rLink.create!(w6r_user_id: W6rUser.create!(name: "n").id, w6r_tag_id: other_tag.id)

    user.w6r_tags.order(label: :desc).limit(2).pluck(:label).map(&.first).should eq(["t3", "t2"])
    user.w6r_tags.count.should eq(3)
    user.w6r_tags.pluck(:label).size.should eq(3)
  end

  it "leaves Enumerable methods on loaded records untouched" do
    user, _ = w6r_fixture
    collection = user.w6r_posts
    collection.load_target

    statements = StatementRecorder.statements do
      collection.map(&.title).compact.sort!.should eq(["a", "b", "c", "d"])
      collection.sum { |post| post.score || 0 }.should eq(11)
      collection.group_by(&.active).size.should eq(2)
    end

    statements.should be_empty
  end
end
