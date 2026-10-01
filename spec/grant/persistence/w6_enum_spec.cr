require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6EnumPost < Grant::Base
    connection {{ adapter_literal }}
    table w6_enum_posts

    column id : Int64, primary: true
    column title : String

    enum Status
      Draft
      Published
      Archived
    end

    enum_attribute status : W6EnumPost::Status = :draft, validate: true
    # An archived value is stored as published: enum and normalizes share the column.
    normalizes :status, with: ->(value : W6EnumPost::Status) { value.archived? ? W6EnumPost::Status::Published : value }

    validate "title must not be blank" do |model|
      !model.title.blank?
    end
  end

  class W6EnumStrict < Grant::Base
    connection {{ adapter_literal }}
    table w6_enum_stricts

    column id : Int64, primary: true

    enum Mode
      On
      Off
    end

    enum_attribute mode : W6EnumStrict::Mode?
  end
{% end %}

describe "Enum attributes" do
  before_all do
    id_column = case CURRENT_ADAPTER
                when "pg"    then "BIGSERIAL PRIMARY KEY"
                when "mysql" then "BIGINT AUTO_INCREMENT PRIMARY KEY"
                else              "INTEGER PRIMARY KEY AUTOINCREMENT"
                end
    W6EnumPost.exec("DROP TABLE IF EXISTS w6_enum_posts")
    W6EnumPost.exec("CREATE TABLE w6_enum_posts (id #{id_column}, title VARCHAR(255) NOT NULL, status VARCHAR(255))")
    W6EnumStrict.exec("DROP TABLE IF EXISTS w6_enum_stricts")
    W6EnumStrict.exec("CREATE TABLE w6_enum_stricts (id #{id_column}, mode VARCHAR(255))")
  end

  before_each do
    W6EnumPost.clear
    W6EnumStrict.clear
  end

  it "returns Rails' name => value mapping from the plural class method" do
    expected = {"draft" => W6EnumPost::Status::Draft, "published" => W6EnumPost::Status::Published, "archived" => W6EnumPost::Status::Archived}
    W6EnumPost.statuses.should eq(expected)
    W6EnumPost.status_mapping.should eq(expected)
    W6EnumPost.statuses.keys.should eq(["draft", "published", "archived"])
  end

  describe "bang setters" do
    it "insert a new record, like update! on a new Rails record" do
      post = W6EnumPost.new(title: "fresh")
      post.published!.should eq(W6EnumPost::Status::Published)
      post.persisted?.should be_true
      W6EnumPost.find!(post.id).status.should eq(W6EnumPost::Status::Published)
    end

    it "validate, so an invalid new record raises and is not inserted" do
      post = W6EnumPost.new(title: "")
      expect_raises(Grant::RecordInvalid) { post.published! }
      post.new_record?.should be_true
      W6EnumPost.count.should eq(0)
    end

    it "update a persisted record" do
      post = W6EnumPost.create!(title: "p")
      post.published!
      W6EnumPost.find!(post.id).status.should eq(W6EnumPost::Status::Published)
    end
  end

  it "reports status_previously_was in the enum type" do
    post = W6EnumPost.create!(title: "p")
    post.assign_published
    post.save!
    post.status_previously_was.should eq(W6EnumPost::Status::Draft)
    typeof(post.status_previously_was).should eq(W6EnumPost::Status?)
    post.status_previously_changed?(from: W6EnumPost::Status::Draft, to: W6EnumPost::Status::Published).should be_true
    post.saved_change_to_status.should eq({W6EnumPost::Status::Draft, W6EnumPost::Status::Published})
  end

  describe "mass assignment of a name" do
    it "uses validate: instead of recording a conversion error" do
      post = W6EnumPost.new(title: "x", status: "bogus")
      post.errors.should be_empty
      post.valid?.should be_false
      post.errors.map(&.message).join.should contain("status is not included in the list")

      post.assign_attributes(status: "published")
      post.valid?.should be_true
      post.status.should eq(W6EnumPost::Status::Published)
    end

    it "accepts a symbol and a member" do
      W6EnumPost.new(title: "x", status: :published).status.should eq(W6EnumPost::Status::Published)
      W6EnumPost.new(title: "x", status: W6EnumPost::Status::Archived).status.should eq(W6EnumPost::Status::Published)
    end

    it "raises UnknownEnumValueError without validate:" do
      expect_raises(Grant::UnknownEnumValueError) { W6EnumStrict.new(mode: "bogus") }
      W6EnumStrict.new(mode: "on").mode.should eq(W6EnumStrict::Mode::On)
    end
  end

  describe "together with normalizes" do
    it "normalizes the assigned member" do
      post = W6EnumPost.new(title: "n")
      post.status = W6EnumPost::Status::Archived
      post.status.should eq(W6EnumPost::Status::Published)
      post.archived?.should be_false
    end

    it "normalizes through the string setter and mass assignment" do
      post = W6EnumPost.new(title: "n")
      post.status = "archived"
      post.status.should eq(W6EnumPost::Status::Published)
    end

    it "keeps where(status:) coercion working on the same column" do
      W6EnumPost.create!(title: "a", status: :published)
      W6EnumPost.create!(title: "b", status: :draft)
      W6EnumPost.where(status: "published").count.should eq(1)
      W6EnumPost.where(status: :draft).count.should eq(1)
      # An archived query value is normalized to published, then stored form.
      W6EnumPost.where(status: W6EnumPost::Status::Archived).count.should eq(1)
      W6EnumPost.find_by(status: "draft").try(&.title).should eq("b")
    end
  end
end
