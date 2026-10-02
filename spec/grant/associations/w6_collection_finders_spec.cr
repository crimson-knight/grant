require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6fUser < Grant::Base
    connection {{ adapter_literal }}
    table w6f_users
    column id : Int64, primary: true
    column name : String?
    has_many :w6f_posts, class_name: W6fPost, foreign_key: :w6f_user_id
    has_many :w6f_links, class_name: W6fLink, foreign_key: :w6f_user_id
    has_many :w6f_tags, class_name: W6fTag, through: :w6f_links
  end

  class W6fPost < Grant::Base
    connection {{ adapter_literal }}
    table w6f_posts
    column id : Int64, primary: true
    column title : String?
    column w6f_user_id : Int64?
  end

  class W6fTag < Grant::Base
    connection {{ adapter_literal }}
    table w6f_tags
    column id : Int64, primary: true
    column label : String?
  end

  class W6fLink < Grant::Base
    connection {{ adapter_literal }}
    table w6f_links
    column id : Int64, primary: true
    column w6f_user_id : Int64?
    column w6f_tag_id : Int64?
    belongs_to :w6f_user, class_name: W6fUser, foreign_key: :w6f_user_id, optional: true
    belongs_to :w6f_tag, class_name: W6fTag, foreign_key: :w6f_tag_id, optional: true
  end
{% end %}

private def w6f_selects(statements : Array(String)) : Array(String)
  statements.select(&.lstrip.upcase.starts_with?("SELECT"))
end

private def w6f_user_with_posts(count : Int32 = 6) : {W6fUser, Array(W6fPost)}
  user = W6fUser.create!(name: "u")
  other = W6fUser.create!(name: "o")
  W6fPost.create!(title: "foreign", w6f_user_id: other.id)
  posts = (1..count).map { |i| W6fPost.create!(title: "p#{i}", w6f_user_id: user.id) }
  {user, posts}
end

describe "association collection ordinal finders and multi-id find" do
  before_all do
    W6fUser.migrator.drop_and_create
    W6fPost.migrator.drop_and_create
    W6fTag.migrator.drop_and_create
    W6fLink.migrator.drop_and_create
  end

  before_each do
    W6fLink.clear
    W6fTag.clear
    W6fPost.clear
    W6fUser.clear
  end

  it "reads first and last with LIMIT instead of loading the association" do
    user, posts = w6f_user_with_posts
    collection = user.w6f_posts
    first = nil
    last = nil
    statements = StatementRecorder.statements do
      first = collection.first
      last = collection.last
    end

    first.not_nil!.id.should eq(posts.first.id)
    last.not_nil!.id.should eq(posts.last.id)
    selects = w6f_selects(statements)
    selects.size.should eq(2)
    selects.each(&.upcase.should(contain("LIMIT 1")))
    selects.last.upcase.should contain("DESC")
    collection.loaded?.should be_false
  end

  it "returns the first and last n records with LIMIT n" do
    user, posts = w6f_user_with_posts
    firsts = [] of W6fPost
    lasts = [] of W6fPost
    statements = StatementRecorder.statements do
      firsts = user.w6f_posts.first(2)
      lasts = user.w6f_posts.last(2)
    end

    firsts.map(&.id).should eq(posts[0, 2].map(&.id))
    lasts.map(&.id).should eq(posts[-2, 2].map(&.id))
    w6f_selects(statements).each(&.upcase.should(contain("LIMIT 2")))
  end

  it "answers take and take(n) without ordering" do
    user, posts = w6f_user_with_posts
    ids = posts.map(&.id)

    ids.should contain(user.w6f_posts.take.not_nil!.id)
    user.w6f_posts.take(3).size.should eq(3)
    user.w6f_posts.take(3).each { |post| ids.should contain(post.id) }
    user.w6f_posts.take!.w6f_user_id.should eq(user.id)
  end

  it "reads second through fifth and forty_two by offset" do
    user, posts = w6f_user_with_posts
    collection = user.w6f_posts

    collection.second.not_nil!.id.should eq(posts[1].id)
    collection.third.not_nil!.id.should eq(posts[2].id)
    collection.fourth.not_nil!.id.should eq(posts[3].id)
    collection.fifth.not_nil!.id.should eq(posts[4].id)
    collection.forty_two.should be_nil
    collection.second_to_last.not_nil!.id.should eq(posts[-2].id)
    collection.third_to_last.not_nil!.id.should eq(posts[-3].id)

    statements = StatementRecorder.statements { collection.third }
    w6f_selects(statements).first.upcase.should contain("OFFSET 2")
  end

  it "returns nil or raises NotFound on an empty collection" do
    user = W6fUser.create!(name: "empty")

    user.w6f_posts.first.should be_nil
    user.w6f_posts.last.should be_nil
    user.w6f_posts.take.should be_nil
    user.w6f_posts.second.should be_nil
    user.w6f_posts.first(2).should be_empty
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.first! }
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.last! }
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.second! }
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.take! }
  end

  it "finds several ids with one IN query, in the order given" do
    user, posts = w6f_user_with_posts
    wanted = [posts[3].id, posts[0].id, posts[2].id]
    found = [] of W6fPost
    statements = StatementRecorder.statements { found = user.w6f_posts.find(wanted) }

    found.map(&.id).should eq(wanted)
    w6f_selects(statements).size.should eq(1)
    user.w6f_posts.find(posts[1].id, posts[4].id).map(&.id).should eq([posts[1].id, posts[4].id])
  end

  it "does not find rows of another owner" do
    user, posts = w6f_user_with_posts
    foreign = W6fPost.find_by!(title: "foreign")

    user.w6f_posts.find(foreign.id).should be_nil
    user.w6f_posts.find([foreign.id, posts[0].id]).map(&.id).should eq([posts[0].id])
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.find!([foreign.id, posts[0].id]) }
    expect_raises(Grant::Querying::NotFound) { user.w6f_posts.find!(foreign.id) }
    user.w6f_posts.find!(posts[0].id).id.should eq(posts[0].id)
  end

  it "answers from the loaded records without a query" do
    user, posts = w6f_user_with_posts
    collection = user.w6f_posts
    collection.load_target

    statements = StatementRecorder.statements do
      collection.first.not_nil!.id.should eq(posts[0].id)
      collection.last(2).map(&.id).should eq(posts[-2, 2].map(&.id))
      collection.take(2).size.should eq(2)
      collection.second.not_nil!.id.should eq(posts[1].id)
      collection.third_to_last.not_nil!.id.should eq(posts[-3].id)
      collection.find([posts[2].id, posts[0].id]).map(&.id).should eq([posts[2].id, posts[0].id])
    end

    statements.should be_empty
  end

  it "reads the ordinals of a has_many :through collection in SQL" do
    user, _ = w6f_user_with_posts(1)
    tags = (1..4).map { |i| W6fTag.create!(label: "t#{i}") }
    tags.each { |tag| W6fLink.create!(w6f_user_id: user.id, w6f_tag_id: tag.id) }
    W6fLink.create!(w6f_user_id: W6fUser.create!(name: "n").id, w6f_tag_id: W6fTag.create!(label: "x").id)

    collection = user.w6f_tags
    collection.first.not_nil!.id.should eq(tags.first.id)
    collection.last.not_nil!.id.should eq(tags.last.id)
    collection.second.not_nil!.id.should eq(tags[1].id)
    collection.first(2).map(&.id).should eq(tags[0, 2].map(&.id))
    collection.find(tags[2].id).not_nil!.id.should eq(tags[2].id)
    collection.find([tags[3].id, tags[0].id]).map(&.id).should eq([tags[3].id, tags[0].id])
    collection.loaded?.should be_false
  end
end
