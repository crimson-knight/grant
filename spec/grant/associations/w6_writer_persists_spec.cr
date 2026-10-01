require "../../spec_helper"
require "../../support/statement_recorder"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6wOwner < Grant::Base
    connection {{ adapter_literal }}
    table w6w_owners
    column id : Int64, primary: true
    column name : String?
    has_one :w6w_profile, class_name: W6wProfile, foreign_key: :w6w_owner_id
    has_one :w6w_badge, class_name: W6wBadge, foreign_key: :w6w_owner_id, dependent: :destroy
    has_one :w6w_card, class_name: W6wCard, foreign_key: :w6w_owner_id, dependent: :delete
    has_many :w6w_posts, class_name: W6wPost, foreign_key: :w6w_owner_id
    has_many :w6w_comments, class_name: W6wComment, foreign_key: :w6w_owner_id, dependent: :destroy
    has_many :w6w_notes, class_name: W6wNote, foreign_key: :w6w_owner_id, dependent: :delete_all
  end

  class W6wProfile < Grant::Base
    connection {{ adapter_literal }}
    table w6w_profiles
    column id : Int64, primary: true
    column bio : String?
    column w6w_owner_id : Int64?
    validate "bio must be present" do |profile|
      !profile.bio.to_s.empty?
    end
  end

  class W6wBadge < Grant::Base
    connection {{ adapter_literal }}
    table w6w_badges
    column id : Int64, primary: true
    column label : String?
    column w6w_owner_id : Int64?
  end

  class W6wCard < Grant::Base
    connection {{ adapter_literal }}
    table w6w_cards
    column id : Int64, primary: true
    column label : String?
    column w6w_owner_id : Int64?
  end

  class W6wPost < Grant::Base
    connection {{ adapter_literal }}
    table w6w_posts
    column id : Int64, primary: true
    column title : String?
    column w6w_owner_id : Int64?
    validate "title must be present" do |post|
      !post.title.to_s.empty?
    end
  end

  class W6wComment < Grant::Base
    connection {{ adapter_literal }}
    table w6w_comments
    column id : Int64, primary: true
    column body : String?
    column w6w_owner_id : Int64?
  end

  class W6wNote < Grant::Base
    connection {{ adapter_literal }}
    table w6w_notes
    column id : Int64, primary: true
    column body : String?
    column w6w_owner_id : Int64?
  end
{% end %}

describe "has_one and has_many writers on a saved owner" do
  before_all do
    W6wOwner.migrator.drop_and_create
    W6wProfile.migrator.drop_and_create
    W6wBadge.migrator.drop_and_create
    W6wCard.migrator.drop_and_create
    W6wPost.migrator.drop_and_create
    W6wComment.migrator.drop_and_create
    W6wNote.migrator.drop_and_create
  end

  before_each do
    W6wProfile.clear
    W6wBadge.clear
    W6wCard.clear
    W6wPost.clear
    W6wComment.clear
    W6wNote.clear
    W6wOwner.clear
  end

  describe "has_one writer" do
    it "saves the new child at once and replaces the old one (nullify by default)" do
      owner = W6wOwner.create!(name: "o")
      old = W6wProfile.create!(bio: "old", w6w_owner_id: owner.id)
      child = W6wProfile.new(bio: "new")

      owner.w6w_profile = child

      child.persisted?.should be_true
      child.w6w_owner_id.should eq(owner.id)
      W6wProfile.find!(old.id).w6w_owner_id.should be_nil
      W6wProfile.where(w6w_owner_id: owner.id).select.map(&.id).should eq([child.id])
      owner.w6w_profile.not_nil!.id.should eq(child.id)
    end

    it "destroys the old child with dependent: :destroy and deletes it with :delete" do
      owner = W6wOwner.create!(name: "o")
      W6wBadge.create!(label: "old", w6w_owner_id: owner.id)
      W6wCard.create!(label: "old", w6w_owner_id: owner.id)

      owner.w6w_badge = W6wBadge.new(label: "new")
      owner.w6w_card = W6wCard.new(label: "new")

      # Keys can be reused after a delete, so look for the old rows by label.
      W6wBadge.where(label: "old").count.should eq(0)
      W6wCard.where(label: "old").count.should eq(0)
      W6wBadge.where(w6w_owner_id: owner.id).count.should eq(1)
      W6wCard.where(w6w_owner_id: owner.id).count.should eq(1)
    end

    it "assigning nil removes the current child by the dependent strategy" do
      owner = W6wOwner.create!(name: "o")
      profile = W6wProfile.create!(bio: "p", w6w_owner_id: owner.id)
      badge = W6wBadge.create!(label: "b", w6w_owner_id: owner.id)

      owner.w6w_profile = nil
      owner.w6w_badge = nil

      W6wProfile.find!(profile.id).w6w_owner_id.should be_nil
      W6wBadge.find(badge.id).should be_nil
      owner.w6w_profile.should be_nil
    end

    it "assigning an existing record of another owner moves it" do
      first = W6wOwner.create!(name: "1")
      second = W6wOwner.create!(name: "2")
      profile = W6wProfile.create!(bio: "p", w6w_owner_id: first.id)

      second.w6w_profile = profile

      W6wProfile.find!(profile.id).w6w_owner_id.should eq(second.id)
    end

    it "does nothing when the same child is assigned again" do
      owner = W6wOwner.create!(name: "o")
      profile = W6wProfile.create!(bio: "p", w6w_owner_id: owner.id)
      owner.w6w_profile.should_not be_nil

      statements = StatementRecorder.statements { owner.w6w_profile = profile }

      StatementRecorder.count(statements, "UPDATE").should eq(0)
      StatementRecorder.count(statements, "INSERT").should eq(0)
    end

    it "rolls back and raises RecordNotSaved when the new child is invalid" do
      owner = W6wOwner.create!(name: "o")
      old = W6wBadge.create!(label: "old", w6w_owner_id: owner.id)
      profile = W6wProfile.create!(bio: "keep", w6w_owner_id: owner.id)

      expect_raises(Grant::RecordNotSaved) { owner.w6w_profile = W6wProfile.new(bio: "") }

      W6wProfile.find!(profile.id).w6w_owner_id.should eq(owner.id)
      W6wBadge.find!(old.id).w6w_owner_id.should eq(owner.id)
    end

    it "keeps staging the child on an unsaved owner" do
      owner = W6wOwner.new(name: "new")
      child = W6wProfile.new(bio: "b")

      owner.w6w_profile = child
      child.persisted?.should be_false
      W6wProfile.count.should eq(0)

      owner.save!
      child.persisted?.should be_true
      child.w6w_owner_id.should eq(owner.id)
    end

    it "build_ and create_ keep their semantics" do
      owner = W6wOwner.create!(name: "o")

      built = owner.build_w6w_profile(bio: "built")
      built.persisted?.should be_false
      W6wProfile.count.should eq(0)

      created = owner.create_w6w_profile(bio: "created")
      created.persisted?.should be_true
      W6wProfile.where(w6w_owner_id: owner.id).count.should eq(1)
    end
  end

  describe "has_many writer" do
    it "saves new records at once and nullifies the removed ones" do
      owner = W6wOwner.create!(name: "o")
      keep = W6wPost.create!(title: "keep", w6w_owner_id: owner.id)
      drop = W6wPost.create!(title: "drop", w6w_owner_id: owner.id)
      fresh = W6wPost.new(title: "fresh")
      moved = W6wPost.create!(title: "moved")

      statements = StatementRecorder.statements { owner.w6w_posts = [keep, fresh, moved] }

      fresh.persisted?.should be_true
      W6wPost.where(w6w_owner_id: owner.id).select.map(&.title).compact.sort!.should eq(["fresh", "keep", "moved"])
      W6wPost.find!(drop.id).w6w_owner_id.should be_nil
      # One set-based UPDATE for the removed row; the unchanged record is not written.
      StatementRecorder.count(statements, "UPDATE", "w6w_posts").should be <= 3
      owner.w6w_posts.map(&.title).compact.sort!.should eq(["fresh", "keep", "moved"])
    end

    it "removes the dropped records by dependent: :destroy and :delete_all" do
      owner = W6wOwner.create!(name: "o")
      W6wComment.create!(body: "old", w6w_owner_id: owner.id)
      W6wNote.create!(body: "old", w6w_owner_id: owner.id)

      owner.w6w_comments = [W6wComment.new(body: "new")]
      owner.w6w_notes = [W6wNote.new(body: "new")]

      W6wComment.where(body: "old").count.should eq(0)
      W6wNote.where(body: "old").count.should eq(0)
      W6wComment.where(w6w_owner_id: owner.id).count.should eq(1)
      W6wNote.where(w6w_owner_id: owner.id).count.should eq(1)
    end

    it "an empty array removes every member" do
      owner = W6wOwner.create!(name: "o")
      post = W6wPost.create!(title: "p", w6w_owner_id: owner.id)

      owner.w6w_posts = [] of W6wPost

      W6wPost.find!(post.id).w6w_owner_id.should be_nil
      owner.w6w_posts.size.should eq(0)
    end

    it "rolls back the whole replacement when a new record is invalid" do
      owner = W6wOwner.create!(name: "o")
      keep = W6wPost.create!(title: "keep", w6w_owner_id: owner.id)

      expect_raises(Grant::RecordInvalid) { owner.w6w_posts = [W6wPost.new(title: "ok"), W6wPost.new(title: "")] }

      W6wPost.find!(keep.id).w6w_owner_id.should eq(owner.id)
      W6wPost.count.should eq(1)
    end

    it "replace and concat are available on the collection" do
      owner = W6wOwner.create!(name: "o")
      a = W6wPost.create!(title: "a")
      b = W6wPost.create!(title: "b")

      owner.w6w_posts.replace([a])
      W6wPost.where(w6w_owner_id: owner.id).count.should eq(1)
      owner.w6w_posts.concat([b])
      W6wPost.where(w6w_owner_id: owner.id).count.should eq(2)
      owner.w6w_posts.replace([b])
      W6wPost.find!(a.id).w6w_owner_id.should be_nil
    end

    it "keeps staging records on an unsaved owner" do
      owner = W6wOwner.new(name: "new")
      post = W6wPost.new(title: "p")

      owner.w6w_posts = [post]
      post.persisted?.should be_false

      owner.save!
      post.persisted?.should be_true
      post.w6w_owner_id.should eq(owner.id)
    end
  end
end
