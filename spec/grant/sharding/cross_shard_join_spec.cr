require "../../spec_helper"
require "../../support/real_sqlite_shards"

class S02JoinAuthor < Grant::Base
  connection "s02_joins"
  table s02_join_authors
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column name : String
  has_many :posts, class_name: S02JoinPost, foreign_key: :author_id
  has_many :ratings, class_name: S02JoinRating, foreign_key: :author_id
  has_many :notes, class_name: S02JoinNote, foreign_key: :author_id
end

# Same shard key and the same placement as S02JoinAuthor: rows join in place.
class S02JoinPost < Grant::Base
  connection "s02_joins"
  table s02_join_posts
  include Grant::Sharding::Model

  shards_by :tenant_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column tenant_id : Int64
  column author_id : Int64
  column title : String
  belongs_to :author, class_name: S02JoinAuthor, foreign_key: :author_id, optional: true
end

# Sharded, but by another key: its rows are not where the author's are.
class S02JoinRating < Grant::Base
  connection "s02_joins"
  table s02_join_ratings
  include Grant::Sharding::Model

  shards_by :author_id, strategy: :lookup, lookup: {"1" => :one, "2" => :two}, default_shard: nil

  column id : Int64, primary: true
  column author_id : Int64
  column stars : Int64
end

# Not sharded at all.
class S02JoinNote < Grant::Base
  connection "s02_joins"
  table s02_join_notes
  column id : Int64, primary: true
  column author_id : Int64
  column body : String
end

S02_JOIN_FIXTURE = Grant::Testing::RealSqliteShards.new(
  "s02_joins", [:one, :two],
  [
    "CREATE TABLE s02_join_authors (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, name TEXT NOT NULL)",
    "CREATE TABLE s02_join_posts (id INTEGER PRIMARY KEY, tenant_id INTEGER NOT NULL, author_id INTEGER NOT NULL, title TEXT NOT NULL)",
    "CREATE TABLE s02_join_ratings (id INTEGER PRIMARY KEY, author_id INTEGER NOT NULL, stars INTEGER NOT NULL)",
    "CREATE TABLE s02_join_notes (id INTEGER PRIMARY KEY, author_id INTEGER NOT NULL, body TEXT NOT NULL)",
  ]
)

describe "Cross-shard join detection" do
  before_all do
    S02_JOIN_FIXTURE.set_up
    S02_JOIN_FIXTURE.exec(:one, "INSERT INTO s02_join_authors (id, tenant_id, name) VALUES (1, 1, 'Ada')")
    S02_JOIN_FIXTURE.exec(:one, "INSERT INTO s02_join_posts (id, tenant_id, author_id, title) VALUES (10, 1, 1, 'Ada post')")
    S02_JOIN_FIXTURE.exec(:two, "INSERT INTO s02_join_authors (id, tenant_id, name) VALUES (2, 2, 'Bo')")
    S02_JOIN_FIXTURE.exec(:two, "INSERT INTO s02_join_posts (id, tenant_id, author_id, title) VALUES (20, 2, 2, 'Bo post')")
  end

  after_all do
    S02_JOIN_FIXTURE.tear_down
  end

  it "joins a model that shares the shard key and resolver" do
    titles = S02JoinAuthor.joins(:posts).where("s02_join_posts.title LIKE ?", "%post").order(id: :asc).select.map(&.name)
    titles.should eq ["Ada", "Bo"]
  end

  it "left-joins a colocated model" do
    S02JoinAuthor.left_joins(:posts).order(id: :asc).select.map(&.name).should eq ["Ada", "Bo"]
  end

  it "joins in the other direction" do
    S02JoinPost.joins(:author).order(id: :asc).select.map(&.title).should eq ["Ada post", "Bo post"]
  end

  it "refuses a join to a model sharded by another key" do
    expect_raises(Grant::Sharding::CrossShardJoinError, /S02JoinRating.*does not share the shard key/) do
      S02JoinAuthor.joins(:ratings)
    end
  end

  it "refuses a join to a model that is not sharded" do
    expect_raises(Grant::Sharding::CrossShardJoinError, /S02JoinNote is not sharded/) do
      S02JoinAuthor.joins(:notes)
    end
    expect_raises(Grant::Sharding::CrossShardJoinError) { S02JoinAuthor.left_joins(:notes) }
  end

  it "refuses an eager_load that would join across shards" do
    expect_raises(Grant::Sharding::CrossShardJoinError) { S02JoinAuthor.eager_load(:notes) }
  end

  it "refuses a join to a table it cannot place" do
    expect_raises(Grant::Sharding::CrossShardJoinError, /placement is unknown/) do
      S02JoinAuthor.joins("s02_join_elsewhere", on: "s02_join_elsewhere.author_id = s02_join_authors.id")
    end
  end

  it "trusts a raw join fragment" do
    relation = S02JoinAuthor.joins("INNER JOIN s02_join_posts ON s02_join_posts.author_id = s02_join_authors.id")
    relation.should be_a(Grant::Sharding::ShardedQueryBuilder(S02JoinAuthor))
  end
end
