require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6cUser < Grant::Base
    connection {{ adapter_literal }}
    table w6c_users
    column id : Int64, primary: true
    column name : String?
    has_many :w6c_posts, class_name: W6cPost, foreign_key: :w6c_user_id
    has_many :w6c_links, class_name: W6cLink, foreign_key: :w6c_user_id
    has_many :w6c_tags, class_name: W6cTag, through: :w6c_links
  end

  class W6cPost < Grant::Base
    connection {{ adapter_literal }}
    table w6c_posts
    column id : Int64, primary: true
    column slug : String?
    column title : String?
    column w6c_user_id : Int64?
    belongs_to :w6c_user, class_name: W6cUser, foreign_key: :w6c_user_id, optional: true
  end

  class W6cTag < Grant::Base
    connection {{ adapter_literal }}
    table w6c_tags
    column id : Int64, primary: true
    column label : String?
  end

  class W6cLink < Grant::Base
    connection {{ adapter_literal }}
    table w6c_links
    column id : Int64, primary: true
    column w6c_user_id : Int64?
    column w6c_tag_id : Int64?
    belongs_to :w6c_user, class_name: W6cUser, foreign_key: :w6c_user_id, optional: true
    belongs_to :w6c_tag, class_name: W6cTag, foreign_key: :w6c_tag_id, optional: true
  end
{% end %}

describe "association collection find_or_create_by family" do
  before_all do
    W6cUser.migrator.drop_and_create
    W6cPost.migrator.drop_and_create
    W6cTag.migrator.drop_and_create
    W6cLink.migrator.drop_and_create
    # The unique index makes create_or_find_by race-safe.
    W6cPost.exec("CREATE UNIQUE INDEX IF NOT EXISTS w6c_posts_slug_unique ON w6c_posts (slug)")
  end

  before_each do
    W6cLink.clear
    W6cTag.clear
    W6cPost.clear
    W6cUser.clear
  end

  it "find_or_create_by finds an existing row of the owner without a write" do
    user = W6cUser.create!(name: "u")
    existing = W6cPost.create!(slug: "a", title: "A", w6c_user_id: user.id)

    found = nil
    statements = StatementRecorder.statements { found = user.w6c_posts.find_or_create_by(slug: "a") }

    found.not_nil!.id.should eq(existing.id)
    StatementRecorder.count(statements, "INSERT").should eq(0)
  end

  it "find_or_create_by creates through the collection with the owner key applied" do
    user = W6cUser.create!(name: "u")
    W6cPost.create!(slug: "o1", title: "shared", w6c_user_id: W6cUser.create!(name: "o").id)

    created = user.w6c_posts.find_or_create_by(title: "shared", &.slug=("u1"))

    created.persisted?.should be_true
    created.w6c_user_id.should eq(user.id)
    created.slug.should eq("u1")
    user.w6c_posts.count.should eq(1)
    W6cPost.count.should eq(2)
  end

  it "find_or_create_by accepts a hash and the bang form raises for an invalid record" do
    user = W6cUser.create!(name: "u")

    user.w6c_posts.find_or_create_by({"slug" => "h"}).w6c_user_id.should eq(user.id)
    user.w6c_posts.find_or_create_by!(slug: "h").slug.should eq("h")
    user.w6c_posts.find_or_create_by!(slug: "k").w6c_user_id.should eq(user.id)
  end

  it "find_or_create_by raises OwnerNotSaved on an unsaved owner when it has to create" do
    user = W6cUser.new(name: "new")

    expect_raises(Grant::Associations::OwnerNotSaved) { user.w6c_posts.find_or_create_by(slug: "x") }
  end

  it "find_or_initialize_by builds on the collection without saving" do
    user = W6cUser.create!(name: "u")
    existing = W6cPost.create!(slug: "a", w6c_user_id: user.id)

    user.w6c_posts.find_or_initialize_by(slug: "a").id.should eq(existing.id)

    built = user.w6c_posts.find_or_initialize_by(slug: "b", &.title=("B"))
    built.new_record?.should be_true
    built.w6c_user_id.should eq(user.id)
    built.title.should eq("B")
    W6cPost.count.should eq(1)
  end

  it "create_or_find_by inserts without a prior SELECT" do
    user = W6cUser.create!(name: "u")

    statements = StatementRecorder.statements do
      user.w6c_posts.create_or_find_by(slug: "fresh").w6c_user_id.should eq(user.id)
    end
    lookups = statements.select { |sql| sql.lstrip.upcase.starts_with?("SELECT") && !sql.upcase.includes?("LAST_INSERT") }
    lookups.should be_empty
    StatementRecorder.count(statements, "INSERT").should eq(1)
  end

  it "create_or_find_by returns the existing row when a unique constraint wins" do
    user = W6cUser.create!(name: "u")
    existing = W6cPost.create!(slug: "dup", title: "first", w6c_user_id: user.id)

    found = user.w6c_posts.create_or_find_by(slug: "dup")
    found.id.should eq(existing.id)
    user.w6c_posts.create_or_find_by!(slug: "dup").id.should eq(existing.id)
    W6cPost.count.should eq(1)

    # The surrounding transaction stays usable after the failed insert.
    W6cUser.transaction do
      user.w6c_posts.create_or_find_by!(slug: "dup").id.should eq(existing.id)
      user.w6c_posts.create!(slug: "next").persisted?.should be_true
    end
  end

  it "applies the owner key when the collection is loaded" do
    user = W6cUser.create!(name: "u")
    collection = user.w6c_posts
    collection.load_target

    created = collection.find_or_create_by(slug: "l")

    created.w6c_user_id.should eq(user.id)
    collection.map(&.slug).should eq(["l"])
  end

  it "creates the join row for a has_many :through collection" do
    user = W6cUser.create!(name: "u")

    tag = user.w6c_tags.find_or_create_by(label: "ruby")
    again = user.w6c_tags.find_or_create_by(label: "ruby")

    again.id.should eq(tag.id)
    W6cLink.where(w6c_user_id: user.id, w6c_tag_id: tag.id).count.should eq(1)
    W6cTag.count.should eq(1)
    user.w6c_tags.find_or_initialize_by(label: "go").new_record?.should be_true
  end
end
