require "../../spec_helper"

describe "has_one :through" do
  before_all do
    ThroughUser.migrator.drop_and_create
    ThroughProfile.migrator.drop_and_create
    ThroughAvatar.migrator.drop_and_create
  end

  before_each do
    ThroughAvatar.clear
    ThroughProfile.clear
    ThroughUser.clear
  end

  it "returns the associated record through an intermediate table" do
    user = ThroughUser.new
    user.name = "Jane"
    user.save.should be_true

    avatar = ThroughAvatar.new
    avatar.url = "https://example.com/jane.png"
    avatar.save.should be_true

    profile = ThroughProfile.new
    profile.bio = "Hello world"
    profile.through_user_id = user.id
    profile.through_avatar_id = avatar.id
    profile.save.should be_true

    result = user.avatar
    result.should_not be_nil
    result.not_nil!.id.should eq(avatar.id)
    result.not_nil!.url.should eq("https://example.com/jane.png")
  end

  it "returns nil when no intermediate record exists" do
    user = ThroughUser.new
    user.name = "Bob"
    user.save.should be_true

    user.avatar.should be_nil
  end

  it "returns nil when intermediate exists but has no target" do
    user = ThroughUser.new
    user.name = "Carol"
    user.save.should be_true

    profile = ThroughProfile.new
    profile.bio = "No avatar"
    profile.through_user_id = user.id
    profile.through_avatar_id = nil
    profile.save.should be_true

    user.avatar.should be_nil
  end

  it "returns the correct record among multiple users" do
    user1 = ThroughUser.new
    user1.name = "Dave"
    user1.save.should be_true

    user2 = ThroughUser.new
    user2.name = "Eve"
    user2.save.should be_true

    avatar1 = ThroughAvatar.new
    avatar1.url = "https://example.com/dave.png"
    avatar1.save.should be_true

    avatar2 = ThroughAvatar.new
    avatar2.url = "https://example.com/eve.png"
    avatar2.save.should be_true

    profile1 = ThroughProfile.new
    profile1.bio = "Dave's profile"
    profile1.through_user_id = user1.id
    profile1.through_avatar_id = avatar1.id
    profile1.save.should be_true

    profile2 = ThroughProfile.new
    profile2.bio = "Eve's profile"
    profile2.through_user_id = user2.id
    profile2.through_avatar_id = avatar2.id
    profile2.save.should be_true

    user1.avatar.not_nil!.url.should eq("https://example.com/dave.png")
    user2.avatar.not_nil!.url.should eq("https://example.com/eve.png")
  end

  describe "#avatar!" do
    it "returns the record when it exists" do
      user = ThroughUser.new
      user.name = "Frank"
      user.save.should be_true

      avatar = ThroughAvatar.new
      avatar.url = "https://example.com/frank.png"
      avatar.save.should be_true

      profile = ThroughProfile.new
      profile.bio = "Frank's profile"
      profile.through_user_id = user.id
      profile.through_avatar_id = avatar.id
      profile.save.should be_true

      result = user.avatar!
      result.url.should eq("https://example.com/frank.png")
    end

    it "raises NotFound when no record exists" do
      user = ThroughUser.new
      user.name = "Grace"
      user.save.should be_true

      expect_raises(Grant::Querying::NotFound) do
        user.avatar!
      end
    end
  end
end

# Test models for has_one :through
class ThroughUser < Grant::Base
  connection sqlite
  table through_users

  column id : Int64, primary: true
  column name : String?

  has_one :profile, class_name: ThroughProfile, foreign_key: :through_user_id
  has_one :avatar, class_name: ThroughAvatar, through: :through_profiles, foreign_key: :through_user_id
end

class ThroughProfile < Grant::Base
  connection sqlite
  table through_profiles

  column id : Int64, primary: true
  column bio : String?
  column through_user_id : Int64?
  column through_avatar_id : Int64?

  belongs_to :through_user, optional: true
  belongs_to :through_avatar, optional: true
end

class ThroughAvatar < Grant::Base
  connection sqlite
  table through_avatars

  column id : Int64, primary: true
  column url : String?
end
