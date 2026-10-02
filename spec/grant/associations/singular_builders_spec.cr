require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class SbUser < Grant::Base
    connection {{ adapter_literal }}
    table sb_users
    column id : Int64, primary: true
    column name : String
    validate :name, "Name cannot be blank" do |user|
      !user.name.to_s.blank?
    end
    has_one :sb_profile, class_name: SbProfile, foreign_key: :sb_user_id
    has_one :sb_badge, class_name: SbBadge, foreign_key: :sb_user_id, dependent: :destroy
    has_one :sb_key, class_name: SbKey, foreign_key: :sb_user_id, dependent: :delete
  end

  class SbProfile < Grant::Base
    connection {{ adapter_literal }}
    table sb_profiles
    column id : Int64, primary: true
    column bio : String
    column sb_user_id : Int64?
    validate :bio, "Bio cannot be blank" do |profile|
      !profile.bio.to_s.blank?
    end
    belongs_to :sb_user, class_name: SbUser, foreign_key: :sb_user_id
    belongs_to :sb_editor, class_name: SbUser, foreign_key: :sb_editor_id, optional: true
    column sb_editor_id : Int64?
  end

  class SbBadge < Grant::Base
    connection {{ adapter_literal }}
    table sb_badges
    column id : Int64, primary: true
    column label : String
    column sb_user_id : Int64?
  end

  class SbKey < Grant::Base
    connection {{ adapter_literal }}
    table sb_keys
    column id : Int64, primary: true
    column label : String
    column sb_user_id : Int64?
  end
{% end %}

describe "singular association builders" do
  before_all do
    SbUser.migrator.drop_and_create
    SbProfile.migrator.drop_and_create
    SbBadge.migrator.drop_and_create
    SbKey.migrator.drop_and_create
  end

  before_each do
    SbProfile.clear
    SbBadge.clear
    SbKey.clear
    SbUser.clear
  end

  describe "belongs_to" do
    it "build_<assoc> returns an unsaved parent and assigns it" do
      profile = SbProfile.new(bio: "hi")
      user = profile.build_sb_user(name: "ada")
      user.should be_a(SbUser)
      user.new_record?.should be_true
      user.name.should eq "ada"
      profile.sb_user.should be(user)
      profile.sb_user_id.should be_nil
      SbUser.count.should eq 0
    end

    it "saves a built parent together with the owner and points the key at it" do
      profile = SbProfile.new(bio: "hi")
      user = profile.build_sb_user(name: "ada")
      profile.save.should be_true
      user.persisted?.should be_true
      profile.sb_user_id.should eq user.id
    end

    it "create_<assoc> saves the parent, then assigns the foreign key, without saving the owner" do
      profile = SbProfile.new(bio: "hi")
      user = profile.create_sb_user(name: "ada")
      user.persisted?.should be_true
      profile.sb_user_id.should eq user.id
      profile.sb_user.should be(user)
      profile.new_record?.should be_true
      SbProfile.count.should eq 0
    end

    it "create_<assoc> returns the invalid parent unsaved, create_<assoc>! raises" do
      profile = SbProfile.new(bio: "hi")
      user = profile.create_sb_user(name: "")
      user.persisted?.should be_false
      user.errors.empty?.should be_false
      profile.sb_user_id.should be_nil
      expect_raises(Grant::RecordInvalid) { profile.create_sb_user!(name: "") }
      SbUser.count.should eq 0
    end

    it "create_<assoc>! saves the parent and assigns the key" do
      profile = SbProfile.new(bio: "hi")
      user = profile.create_sb_user!(name: "ada")
      SbUser.find!(user.id).name.should eq "ada"
      profile.sb_user_id.should eq user.id
    end

    it "uses the association name, not the class name, for custom associations" do
      profile = SbProfile.create!(bio: "hi", sb_user_id: SbUser.create!(name: "owner").id)
      editor = profile.create_sb_editor!(name: "ed")
      profile.sb_editor_id.should eq editor.id
      profile.save!
      SbProfile.find!(profile.id).sb_editor!.name.should eq "ed"
      profile.build_sb_editor(name: "next").new_record?.should be_true
    end
  end

  describe "has_one" do
    it "build_<assoc> returns an unsaved child with the owner's key, stored as the loaded target" do
      user = SbUser.create!(name: "ada")
      profile = user.build_sb_profile(bio: "hello")
      profile.should be_a(SbProfile)
      profile.new_record?.should be_true
      profile.bio.should eq "hello"
      profile.sb_user_id.should eq user.id
      user.sb_profile.should be(profile)
      SbProfile.count.should eq 0
    end

    it "saves a built child with the owner" do
      user = SbUser.create!(name: "ada")
      profile = user.build_sb_profile(bio: "hello")
      user.save!
      profile.persisted?.should be_true
      SbProfile.find_by!(sb_user_id: user.id).bio.should eq "hello"
    end

    it "builds for an unsaved owner and gives the child its key when the owner is saved" do
      user = SbUser.new(name: "ada")
      profile = user.build_sb_profile(bio: "hello")
      profile.sb_user_id.should be_nil
      user.save!
      profile.persisted?.should be_true
      profile.sb_user_id.should eq user.id
    end

    it "create_<assoc> saves the child with the owner's key" do
      user = SbUser.create!(name: "ada")
      profile = user.create_sb_profile(bio: "hello")
      profile.persisted?.should be_true
      profile.sb_user_id.should eq user.id
      user.sb_profile.should be(profile)
      SbProfile.find!(profile.id).sb_user_id.should eq user.id
    end

    it "create_<assoc> needs a saved owner" do
      user = SbUser.new(name: "ada")
      expect_raises(Grant::Associations::OwnerNotSaved, /unless the parent is saved/) { user.create_sb_profile(bio: "hello") }
      expect_raises(Grant::Associations::OwnerNotSaved, /unless the parent is saved/) { user.create_sb_profile!(bio: "hello") }
      SbProfile.count.should eq 0
    end

    it "create_<assoc> returns an invalid child unsaved, create_<assoc>! raises" do
      user = SbUser.create!(name: "ada")
      profile = user.create_sb_profile(bio: "")
      profile.persisted?.should be_false
      profile.errors.empty?.should be_false
      expect_raises(Grant::RecordInvalid) { user.create_sb_profile!(bio: "") }
      SbProfile.count.should eq 0
    end

    it "clears the key of the child it replaces by default" do
      user = SbUser.create!(name: "ada")
      old = user.create_sb_profile!(bio: "old")
      fresh = user.create_sb_profile!(bio: "new")
      SbProfile.find!(old.id).sb_user_id.should be_nil
      SbProfile.find!(fresh.id).sb_user_id.should eq user.id
      SbUser.find!(user.id).sb_profile.try(&.bio).should eq "new"
    end

    it "destroys the child it replaces under dependent: :destroy" do
      user = SbUser.create!(name: "ada")
      user.create_sb_badge!(label: "old")
      user.create_sb_badge!(label: "new")
      SbBadge.where(label: "old").count.should eq 0
      SbBadge.count.should eq 1
    end

    it "deletes the child it replaces under dependent: :delete" do
      user = SbUser.create!(name: "ada")
      user.create_sb_key!(label: "old")
      user.build_sb_key(label: "new")
      SbKey.count.should eq 0
    end

    it "keeps the old child when create_<assoc>! fails" do
      user = SbUser.create!(name: "ada")
      old = user.create_sb_profile!(bio: "old")
      expect_raises(Grant::RecordInvalid) { user.create_sb_profile!(bio: "") }
      SbProfile.find!(old.id).sb_user_id.should eq user.id
    end

    it "leaves other owners' children alone" do
      first = SbUser.create!(name: "ada")
      second = SbUser.create!(name: "ben")
      kept = second.create_sb_profile!(bio: "ben's")
      first.create_sb_profile!(bio: "one")
      first.create_sb_profile!(bio: "two")
      SbProfile.find!(kept.id).sb_user_id.should eq second.id
    end
  end
end
