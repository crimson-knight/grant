require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class AsvAuthor < Grant::Base
    connection {{ adapter_literal }}
    table asv_authors
    column id : Int64, primary: true
    column name : String?

    has_many :asv_posts, class_name: AsvPost, foreign_key: :asv_author_id, autosave: true, index_errors: true
    has_many :asv_notes, class_name: AsvNote, foreign_key: :asv_author_id, autosave: true
    has_many :asv_plain_posts, class_name: AsvPlainPost, foreign_key: :asv_author_id
    has_many :asv_lax_posts, class_name: AsvLaxPost, foreign_key: :asv_author_id, validate: false
    has_many :asv_frozen_posts, class_name: AsvFrozenPost, foreign_key: :asv_author_id, autosave: false
    has_one :asv_profile, class_name: AsvProfile, foreign_key: :asv_author_id, autosave: true
  end

  class AsvPost < Grant::Base
    connection {{ adapter_literal }}
    table asv_posts
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column title : String?
    validates_presence_of :title
    belongs_to :asv_author, class_name: AsvAuthor, foreign_key: asv_author_id : Int64?
    has_many :asv_comments, class_name: AsvComment, foreign_key: :asv_post_id, autosave: true
  end

  class AsvKeyed < Grant::Base
    connection {{ adapter_literal }}
    table asv_keyeds
    column id : Int64, primary: true
    column external_ref : Int64
    has_many :asv_key_items, class_name: AsvKeyItem, foreign_key: :keyed_ref, primary_key: :external_ref, autosave: true
    has_one :asv_key_detail, class_name: AsvKeyDetail, foreign_key: :keyed_ref, primary_key: :external_ref, autosave: true
  end

  class AsvKeyItem < Grant::Base
    connection {{ adapter_literal }}
    table asv_key_items
    column id : Int64, primary: true
    column keyed_ref : Int64?
    column title : String?
  end

  class AsvKeyDetail < Grant::Base
    connection {{ adapter_literal }}
    table asv_key_details
    column id : Int64, primary: true
    column keyed_ref : Int64?
    column note : String?
  end

  class AsvComment < Grant::Base
    connection {{ adapter_literal }}
    table asv_comments
    column id : Int64, primary: true
    column asv_post_id : Int64?
    column body : String?
  end

  class AsvNote < Grant::Base
    connection {{ adapter_literal }}
    table asv_notes
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column title : String?
    validates_presence_of :title
  end

  class AsvPlainPost < Grant::Base
    connection {{ adapter_literal }}
    table asv_plain_posts
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column title : String?
    validates_presence_of :title
  end

  class AsvLaxPost < Grant::Base
    connection {{ adapter_literal }}
    table asv_lax_posts
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column title : String?
    validates_presence_of :title
  end

  class AsvFrozenPost < Grant::Base
    connection {{ adapter_literal }}
    table asv_frozen_posts
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column title : String?
  end

  class AsvProfile < Grant::Base
    connection {{ adapter_literal }}
    table asv_profiles
    column id : Int64, primary: true
    column asv_author_id : Int64?
    column bio : String?
    validates_presence_of :bio
  end
{% end %}

describe "association autosave and validate:" do
  before_all do
    AsvAuthor.migrator.drop_and_create
    AsvPost.migrator.drop_and_create
    AsvNote.migrator.drop_and_create
    AsvComment.migrator.drop_and_create
    AsvKeyed.migrator.drop_and_create
    AsvKeyItem.migrator.drop_and_create
    AsvKeyDetail.migrator.drop_and_create
    AsvPlainPost.migrator.drop_and_create
    AsvLaxPost.migrator.drop_and_create
    AsvFrozenPost.migrator.drop_and_create
    AsvProfile.migrator.drop_and_create
  end

  before_each do
    AsvPost.clear
    AsvComment.clear
    AsvKeyItem.clear
    AsvKeyDetail.clear
    AsvKeyed.clear
    AsvNote.clear
    AsvPlainPost.clear
    AsvLaxPost.clear
    AsvFrozenPost.clear
    AsvProfile.clear
    AsvAuthor.clear
  end

  describe "autosave: true" do
    it "makes owner.save return false for an invalid new child, writing nothing" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_notes.build(title: "")

      author.save.should be_false
      author.new_record?.should be_true
      AsvAuthor.count.should eq(0)
      AsvNote.count.should eq(0)
      author.errors["asv_notes.title"].should eq(["can't be blank"])
      author.errors["asv_notes"].should be_empty
    end

    it "saves valid new children with the owner and sets their keys" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_posts.build(title: "One")
      author.asv_posts.build(title: "Two")

      author.save.should be_true
      AsvPost.where(asv_author_id: author.id).select.map(&.title.to_s).sort.should eq(["One", "Two"])
    end

    it "keys errors by position with index_errors: true" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_posts.build(title: "Fine")
      author.asv_posts.build(title: "")

      author.valid?.should be_false
      author.errors["asv_posts[1].title"].should eq(["can't be blank"])
      author.errors["asv_posts.title"].should be_empty
    end

    it "validates a changed loaded child" do
      author = AsvAuthor.create!(name: "Ann")
      post = AsvPost.create!(title: "Keep", asv_author_id: author.id)
      author = AsvAuthor.find!(author.id)
      author.asv_posts.load_target.first.title = ""

      author.save.should be_false
      author.errors["asv_posts[0].title"].should eq(["can't be blank"])
      AsvPost.find!(post.id).title.should eq("Keep")
    end

    it "saves only new or changed children" do
      author = AsvAuthor.create!(name: "Ann")
      first = AsvPost.create!(title: "One", asv_author_id: author.id)
      AsvPost.create!(title: "Two", asv_author_id: author.id)
      author = AsvAuthor.find!(author.id)
      loaded = author.asv_posts.load_target
      loaded.find { |post| post.id == first.id }.not_nil!.title = "One edited"

      statements = StatementRecorder.statements { author.save.should be_true }

      StatementRecorder.count(statements, "UPDATE", "asv_posts").should eq(1)
      StatementRecorder.count(statements, "INSERT", "asv_posts").should eq(0)
      AsvPost.find!(first.id).title.should eq("One edited")
    end

    it "saves a change made two levels down through nested autosave" do
      author = AsvAuthor.create!(name: "Ann")
      post = AsvPost.create!(title: "Post", asv_author_id: author.id)
      comment = AsvComment.create!(body: "old", asv_post_id: post.id)

      author = AsvAuthor.find!(author.id)
      loaded_post = author.asv_posts.load_target.first
      loaded_post.asv_comments.load_target.first.body = "new"

      loaded_post.changed?.should be_false
      loaded_post.changed_for_autosave?.should be_true
      author.save.should be_true
      AsvComment.find!(comment.id).body.should eq("new")
    end

    it "validates and saves a changed has_one child" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_profile = AsvProfile.new(bio: "")

      author.save.should be_false
      author.errors["asv_profile.bio"].should eq(["can't be blank"])

      author.asv_profile = AsvProfile.new(bio: "Hi")
      author.save.should be_true
      AsvProfile.find_by(asv_author_id: author.id).not_nil!.bio.should eq("Hi")
    end
  end

  describe "a configured owner key" do
    it "points saved children at the configured key, not the primary key" do
      owner = AsvKeyed.new(external_ref: 777_i64)
      owner.asv_key_items.build(title: "item")
      owner.asv_key_detail = AsvKeyDetail.new(note: "detail")

      owner.save.should be_true

      AsvKeyItem.where(keyed_ref: 777_i64).count.should eq(1)
      AsvKeyDetail.where(keyed_ref: 777_i64).count.should eq(1)
    end
  end

  describe "the default (no autosave option)" do
    it "adds a single 'is invalid' error on the association for an invalid new child" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_plain_posts.build(title: "")

      author.save.should be_false
      author.errors["asv_plain_posts"].should eq(["is invalid"])
      AsvAuthor.count.should eq(0)
    end

    it "saves new children with the owner" do
      author = AsvAuthor.create!(name: "Ann")
      author.asv_plain_posts.build(title: "Late")

      author.save.should be_true
      AsvPlainPost.where(asv_author_id: author.id).count.should eq(1)
    end

    it "leaves an unchanged persisted child alone" do
      author = AsvAuthor.create!(name: "Ann")
      AsvPlainPost.create!(title: "Old", asv_author_id: author.id)
      author = AsvAuthor.find!(author.id)
      author.asv_plain_posts.load_target

      statements = StatementRecorder.statements { author.save.should be_true }
      StatementRecorder.count(statements, "UPDATE", "asv_plain_posts").should eq(0)
    end
  end

  describe "validate: false" do
    it "skips the owner-side validation of the children" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_lax_posts.build(title: "")

      author.valid?.should be_true
    end

    it "still refuses to write an invalid child" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_lax_posts.build(title: "")

      expect_raises(Grant::RecordInvalid) { author.save }
      AsvAuthor.count.should eq(0)
    end
  end

  describe "autosave: false" do
    it "does not save the associated records" do
      author = AsvAuthor.new(name: "Ann")
      author.asv_frozen_posts.build(title: "Never")

      author.save.should be_true
      AsvFrozenPost.count.should eq(0)
    end
  end
end
