require "./attribute_models"
require "../../support/relation_sql_capture"

describe "cache keys and to_param" do
  before_each do
    AttrPost.clear
    AttrSlugged.clear
    AttrPlain.clear
  end

  it "builds keys for new and persisted records" do
    post = AttrPost.new
    post.to_key.should be_nil
    post.to_param.should be_nil
    post.cache_key.should eq("attr_posts/new")

    post.save!
    post.to_key.should eq([post.id])
    post.to_param.should eq(post.id.to_s)
    post.cache_key.should eq("attr_posts/#{post.id}")
  end

  it "versions from the in-memory updated_at without querying" do
    post = AttrPost.create!(title: "v")
    stamp = post.updated_at!
    expected = stamp.to_utc.to_s("%Y%m%d%H%M%S%6N")

    statements = capture_sql do
      post.cache_version.should eq(expected)
      post.cache_key_with_version.should eq("attr_posts/#{post.id}-#{expected}")
    end
    statements.should be_empty
  end

  it "has no version without an updated_at" do
    plain = AttrPlain.create!(note: "n")
    plain.cache_version.should be_nil
    plain.cache_key_with_version.should eq(plain.cache_key)
  end

  it "supports to_param :column overrides" do
    slugged = AttrSlugged.new(slug: "hello-world")
    slugged.to_param.should be_nil
    slugged.save!
    slugged.to_param.should eq("hello-world")
  end

  it "builds collection_cache_key from one aggregate query" do
    AttrPost.create!(title: "a")
    newest = AttrPost.create!(title: "b")
    relation = AttrPost.where(published: nil)

    key = nil
    statements = capture_sql { key = relation.collection_cache_key }
    statements.size.should eq(1)
    statements.first.should contain("COUNT(*)")
    statements.first.should contain("MAX(")

    key.to_s.should start_with("attr_posts/query-")
    key.to_s.should contain("-2-")
    key.to_s.should end_with(newest.updated_at!.to_utc.to_s("%Y%m%d%H%M%S%6N"))
  end

  it "changes collection_cache_key when rows change" do
    AttrPost.create!(title: "a")
    before = AttrPost.collection_cache_key
    AttrPost.create!(title: "b")
    AttrPost.collection_cache_key.should_not eq(before)
  end
end
