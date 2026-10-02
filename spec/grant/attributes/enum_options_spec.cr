require "../../spec_helper"

class EnoPost < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table eno_posts

  column id : Int64, primary: true
  column title : String

  enum Status
    Draft
    Published
    Archived
  end

  enum Visibility
    Draft
    Public
  end

  enum Level
    Low
    High
  end

  enum_attribute status : EnoPost::Status = :draft, prefix: true
  enum_attribute visibility : EnoPost::Visibility = :public, suffix: :vis, scopes: false
  enum_attribute level : EnoPost::Level?, column_type: Int32, validate: {allow_nil: true}
end

class EnoStrict < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table eno_stricts

  column id : Int64, primary: true

  enum Mode
    On
    Off
  end

  enum_attribute mode : EnoStrict::Mode?, validate: true
end

class EnoGuarded < Grant::Base
  connection {{ (env("CURRENT_ADAPTER") || "sqlite").id }}
  table eno_guardeds

  column id : Int64, primary: true
  column title : String

  enum Stage
    Open
    Closed
  end

  enum_attribute stage : EnoGuarded::Stage = :open

  validate "title must not be blank" do |model|
    !model.title.blank?
  end
end

describe "enum_attribute options" do
  before_all do
    id_column = case CURRENT_ADAPTER
                when "pg"    then "BIGSERIAL PRIMARY KEY"
                when "mysql" then "BIGINT AUTO_INCREMENT PRIMARY KEY"
                else              "INTEGER PRIMARY KEY AUTOINCREMENT"
                end
    EnoPost.exec("DROP TABLE IF EXISTS eno_posts")
    EnoPost.exec("CREATE TABLE eno_posts (id #{id_column}, title VARCHAR(255) NOT NULL, status VARCHAR(255), visibility VARCHAR(255), level INTEGER)")
    EnoStrict.exec("DROP TABLE IF EXISTS eno_stricts")
    EnoStrict.exec("CREATE TABLE eno_stricts (id #{id_column}, mode VARCHAR(255))")
    EnoGuarded.exec("DROP TABLE IF EXISTS eno_guardeds")
    EnoGuarded.exec("CREATE TABLE eno_guardeds (id #{id_column}, title VARCHAR(255) NOT NULL, stage VARCHAR(255))")
  end

  before_each do
    EnoPost.clear
    EnoStrict.clear
    EnoGuarded.clear
  end

  it "prefixes predicates and scopes so shared member names do not collide" do
    post = EnoPost.new(title: "t")
    post.status_draft?.should be_true
    post.status_published?.should be_false
    post.draft_vis?.should be_false # Visibility::Draft, unset default is Public
    post.public_vis?.should be_true
  end

  it "generates not_<member> scopes" do
    EnoPost.create!(title: "a", status: :draft)
    EnoPost.create!(title: "b", status: :published)
    EnoPost.create!(title: "c", status: :archived)
    EnoPost.status_published.count.should eq(1)
    EnoPost.not_status_published.count.should eq(2)
    EnoPost.not_status_draft.map(&.title).sort!.should eq(["b", "c"])
  end

  it "omits scopes with scopes: false" do
    EnoPost.responds_to?(:draft_vis).should be_false
    EnoPost.responds_to?(:not_draft_vis).should be_false
    EnoPost.responds_to?(:status_draft).should be_true
  end

  it "persists a bang setter on a saved record and validates" do
    post = EnoPost.create!(title: "p")
    post.status_published!.should eq(EnoPost::Status::Published)
    EnoPost.find!(post.id).status.should eq(EnoPost::Status::Published)
    post.status_changed?.should be_false
  end

  it "runs validations in the persisting bang setter" do
    strict = EnoStrict.create!(mode: :on)
    strict.mode = nil
    expect_raises(Grant::RecordInvalid) { strict.save! }
  end

  it "raises from the persisting bang setter when validation fails" do
    guarded = EnoGuarded.create!(title: "ok")
    guarded.title = ""
    expect_raises(Grant::RecordInvalid) { guarded.closed! }
    EnoGuarded.find!(guarded.id).stage.should eq(EnoGuarded::Stage::Open)
  end

  it "inserts a new record, like update! does" do
    post = EnoPost.new(title: "n")
    post.status_archived!
    post.status.should eq(EnoPost::Status::Archived)
    post.new_record?.should be_false
    EnoPost.find!(post.id).status.should eq(EnoPost::Status::Archived)
  end

  it "assigns in memory with assign_<member>" do
    post = EnoPost.create!(title: "m")
    post.assign_status_published.should eq(EnoPost::Status::Published)
    post.status.should eq(EnoPost::Status::Published)
    EnoPost.find!(post.id).status.should eq(EnoPost::Status::Draft)
    post.status_changed?.should be_true
  end

  it "looks values up by name and symbol in where and find_by" do
    EnoPost.create!(title: "x", status: :published)
    EnoPost.create!(title: "y", status: :draft)
    EnoPost.where(status: "published").count.should eq(1)
    EnoPost.where(status: :published).count.should eq(1)
    EnoPost.where(status: EnoPost::Status::Published).count.should eq(1)
    EnoPost.find_by(status: "published").try(&.title).should eq("x")
    EnoPost.where(status: ["published", "draft"]).count.should eq(2)
  end

  it "coerces names to integer storage" do
    EnoPost.create!(title: "lv", level: :high)
    EnoPost.where(level: "high").count.should eq(1)
    EnoPost.where(level: "low").count.should eq(0)
  end

  it "exposes the name-to-value mapping" do
    EnoPost.status_mapping.should eq({"draft" => EnoPost::Status::Draft, "published" => EnoPost::Status::Published, "archived" => EnoPost::Status::Archived})
    EnoPost.statuses.values.should eq(EnoPost::Status.values)
  end

  it "raises for an unknown name without validate:" do
    post = EnoPost.new(title: "t")
    expect_raises(Grant::UnknownEnumValueError) { post.status = "bogus" }
  end

  it "reports an unknown name as a validation error with validate:" do
    strict = EnoStrict.new
    strict.mode = "bogus"
    strict.valid?.should be_false
    strict.errors.map(&.message).join.should contain("mode is not included in the list")
    strict.mode = "on"
    strict.valid?.should be_true
  end

  it "forgets an unknown name once a member is assigned directly" do
    strict = EnoStrict.new
    strict.mode = "bogus"
    strict.valid?.should be_false
    strict.mode = EnoStrict::Mode::Off
    strict.valid?.should be_true
  end

  it "requires a value with validate: true and allows nil with allow_nil" do
    EnoStrict.new.valid?.should be_false
    EnoPost.new(title: "t").valid?.should be_true
  end
end
