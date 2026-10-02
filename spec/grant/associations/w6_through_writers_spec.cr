require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6tPost < Grant::Base
    connection {{ adapter_literal }}
    table w6t_posts
    column id : Int64, primary: true
    column title : String?
    has_many :w6t_taggings, class_name: W6tTagging, foreign_key: :w6t_post_id
    has_many :w6t_tags, class_name: W6tTag, through: :w6t_taggings
  end

  class W6tTag < Grant::Base
    connection {{ adapter_literal }}
    table w6t_tags
    column id : Int64, primary: true
    column label : String?
    validate "label must be present" do |tag|
      !tag.label.to_s.empty?
    end
  end

  class W6tTagging < Grant::Base
    connection {{ adapter_literal }}
    table w6t_taggings
    column id : Int64, primary: true
    column w6t_post_id : Int64?
    column w6t_tag_id : Int64?
    belongs_to :w6t_post, class_name: W6tPost, foreign_key: :w6t_post_id, optional: true
    belongs_to :w6t_tag, class_name: W6tTag, foreign_key: :w6t_tag_id, optional: true
  end
{% end %}

private def w6t_tags(count : Int32) : Array(W6tTag)
  (1..count).map { |i| W6tTag.create!(label: "t#{i}") }
end

private def w6t_link_keys(post : W6tPost) : Array(Int64?)
  W6tTagging.where(w6t_post_id: post.id).select.map(&.w6t_tag_id).sort_by! { |key| key || 0_i64 }
end

describe "has_many :through collection writers" do
  before_all do
    W6tPost.migrator.drop_and_create
    W6tTag.migrator.drop_and_create
    W6tTagging.migrator.drop_and_create
  end

  before_each do
    W6tTagging.clear
    W6tTag.clear
    W6tPost.clear
  end

  it "<< saves a new target and inserts the join row with both keys" do
    post = W6tPost.create!(title: "p")
    fresh = W6tTag.new(label: "fresh")
    saved = w6t_tags(1).first

    post.w6t_tags << saved
    post.w6t_tags << fresh

    fresh.persisted?.should be_true
    link = W6tTagging.find_by!(w6t_tag_id: fresh.id)
    link.w6t_post_id.should eq(post.id)
    w6t_link_keys(post).should eq([saved.id, fresh.id].sort_by(&.not_nil!))
    W6tTag.count.should eq(2)
  end

  it "<< with several targets writes one multi-row INSERT for the join rows" do
    post = W6tPost.create!(title: "p")
    tags = w6t_tags(3)

    statements = StatementRecorder.statements { post.w6t_tags.concat(tags) }

    StatementRecorder.count(statements, "INSERT INTO", "w6t_taggings").should eq(1)
    w6t_link_keys(post).size.should eq(3)
  end

  it "build and create add the join row" do
    post = W6tPost.create!(title: "p")

    built = post.w6t_tags.build(label: "built")
    built.new_record?.should be_true
    W6tTagging.count.should eq(0)
    post.save!
    # The owner had no change to save; the pending join waits for an owner save.
    post.title = "p2"
    post.save!

    built.persisted?.should be_true
    W6tTagging.where(w6t_post_id: post.id, w6t_tag_id: built.id).count.should eq(1)

    created = post.w6t_tags.create(label: "created")
    created.persisted?.should be_true
    W6tTagging.where(w6t_post_id: post.id, w6t_tag_id: created.id).count.should eq(1)
    post.w6t_tags.create!(label: "bang").persisted?.should be_true
    post.w6t_tags.count.should eq(3)
  end

  it "create! raises for an invalid target and inserts no join row" do
    post = W6tPost.create!(title: "p")

    expect_raises(Grant::RecordInvalid) { post.w6t_tags.create!(label: "") }
    W6tTagging.count.should eq(0)
    W6tTag.count.should eq(0)
  end

  it "delete(record) removes only that join row and keeps the target" do
    post = W6tPost.create!(title: "p")
    other = W6tPost.create!(title: "o")
    a, b, c = w6t_tags(3)
    post.w6t_tags.concat([a, b, c])
    other.w6t_tags << a

    removed = post.w6t_tags.delete(a)

    removed.map(&.id).should eq([a.id])
    w6t_link_keys(post).should eq([b.id, c.id].sort_by(&.not_nil!))
    W6tTagging.where(w6t_post_id: other.id, w6t_tag_id: a.id).count.should eq(1)
    W6tTag.count.should eq(3)
    post.w6t_tags.delete(b, c).size.should eq(2)
    W6tTagging.where(w6t_post_id: post.id).count.should eq(0)
  end

  it "delete(record) issues one DELETE for the join rows" do
    post = W6tPost.create!(title: "p")
    a, b = w6t_tags(2)
    post.w6t_tags.concat([a, b])

    statements = StatementRecorder.statements { post.w6t_tags.delete(a, b) }

    StatementRecorder.count(statements, "DELETE FROM", "w6t_taggings").should eq(1)
  end

  it "clear removes every join row of the owner and keeps the targets" do
    post = W6tPost.create!(title: "p")
    other = W6tPost.create!(title: "o")
    tags = w6t_tags(3)
    post.w6t_tags.concat(tags)
    other.w6t_tags << tags.first

    post.w6t_tags.clear

    W6tTagging.where(w6t_post_id: post.id).count.should eq(0)
    W6tTagging.where(w6t_post_id: other.id).count.should eq(1)
    W6tTag.count.should eq(3)
    post.w6t_tags.count.should eq(0)
  end

  it "ids= diffs the keys with one INSERT and one DELETE" do
    post = W6tPost.create!(title: "p")
    a, b, c, d = w6t_tags(4)
    post.w6t_tags.concat([a, b])

    statements = StatementRecorder.statements { post.w6t_tag_ids = [b.id, c.id, d.id] }

    StatementRecorder.count(statements, "INSERT INTO", "w6t_taggings").should eq(1)
    StatementRecorder.count(statements, "DELETE FROM", "w6t_taggings").should eq(1)
    w6t_link_keys(post).should eq([b.id, c.id, d.id].sort_by(&.not_nil!))
    post.w6t_tag_ids.sort!.should eq([b.id, c.id, d.id].sort_by(&.not_nil!))
  end

  it "ids= casts numeric strings and raises RecordNotFound for a missing key" do
    post = W6tPost.create!(title: "p")
    a, b = w6t_tags(2)

    post.w6t_tag_ids = [a.id.to_s, "", nil, b.id.to_s]
    w6t_link_keys(post).size.should eq(2)

    expect_raises(Grant::RecordNotFound, /999999/) { post.w6t_tag_ids = [a.id, 999_999_i64] }
    w6t_link_keys(post).size.should eq(2)

    post.w6t_tag_ids = [] of Int64
    W6tTagging.count.should eq(0)
    W6tTag.count.should eq(2)
  end

  it "the collection writer replaces the members on a saved owner" do
    post = W6tPost.create!(title: "p")
    a, b, c = w6t_tags(3)
    post.w6t_tags.concat([a, b])

    post.w6t_tags = [b, c]

    w6t_link_keys(post).should eq([b.id, c.id].sort_by(&.not_nil!))
    W6tTag.count.should eq(3)
    post.w6t_tags.map(&.id.not_nil!).sort!.should eq([b.id, c.id].sort_by(&.not_nil!))
  end

  it "keeps appended targets until a new owner is saved" do
    post = W6tPost.new(title: "new")
    tag = w6t_tags(1).first

    post.w6t_tags << tag
    post.w6t_tags.build(label: "pending")
    W6tTagging.count.should eq(0)
    post.w6t_tags.size.should eq(2)

    post.save!

    W6tTagging.where(w6t_post_id: post.id).count.should eq(2)
  end

  it "rolls back every join row when one target is invalid" do
    post = W6tPost.create!(title: "p")
    good = W6tTag.new(label: "good")
    bad = W6tTag.new(label: "")

    expect_raises(Grant::RecordInvalid) { post.w6t_tags.concat([good, bad]) }

    W6tTagging.count.should eq(0)
  end
end
