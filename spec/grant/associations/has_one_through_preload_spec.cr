require "../../spec_helper"
require "../../support/association_query_counter"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class HtUser < Grant::Base
    connection {{ adapter_literal }}
    table ht_users
    column id : Int64, primary: true
    column name : String
    has_one :ht_profile, class_name: HtProfile, foreign_key: :ht_user_id
    has_one :ht_badge, through: :ht_profile, source: :ht_badge, class_name: HtBadge
    has_one :active_badge, -> { where(active: true) }, through: :ht_profile, source: :ht_badge, class_name: HtBadge
  end

  class HtProfile < Grant::Base
    connection {{ adapter_literal }}
    table ht_profiles
    column id : Int64, primary: true
    column ht_user_id : Int64?
    column ht_badge_id : Int64?
    belongs_to :ht_user, class_name: HtUser, foreign_key: :ht_user_id, optional: true
    belongs_to :ht_badge, class_name: HtBadge, foreign_key: :ht_badge_id, optional: true
  end

  class HtBadge < Grant::Base
    connection {{ adapter_literal }}
    table ht_badges
    column id : Int64, primary: true
    column label : String
    column active : Bool = true
  end
{% end %}

def user_with_badge(name : String, active : Bool = true) : {HtUser, HtBadge}
  user = HtUser.create!(name: name)
  badge = HtBadge.create!(label: "#{name} badge", active: active)
  HtProfile.create!(ht_user_id: user.id, ht_badge_id: badge.id)
  {user, badge}
end

describe "has_one :through preloading" do
  before_all do
    HtUser.migrator.drop_and_create
    HtProfile.migrator.drop_and_create
    HtBadge.migrator.drop_and_create
  end

  before_each do
    HtProfile.clear
    HtBadge.clear
    HtUser.clear
  end

  it "loads the target instead of silently leaving nil" do
    user, badge = user_with_badge("ada")

    loaded = HtUser.includes(:ht_badge).where(id: user.id).select.first
    loaded.association_loaded?(:ht_badge).should be_true
    loaded.ht_badge.try(&.id).should eq(badge.id)
    HtUser.find!(user.id).ht_badge.try(&.id).should eq(badge.id)
  end

  it "resolves each owner to its own target, nil where the chain is broken" do
    ada, ada_badge = user_with_badge("ada")
    bob, bob_badge = user_with_badge("bob")
    no_profile = HtUser.create!(name: "no profile")
    no_badge = HtUser.create!(name: "no badge")
    HtProfile.create!(ht_user_id: no_badge.id, ht_badge_id: nil)

    users = HtUser.includes(:ht_badge).order(:id).select.index_by(&.id)
    users[ada.id].ht_badge.try(&.id).should eq(ada_badge.id)
    users[bob.id].ht_badge.try(&.id).should eq(bob_badge.id)
    users[no_profile.id].ht_badge.should be_nil
    users[no_badge.id].ht_badge.should be_nil
    users.each_value { |user| user.association_loaded?(:ht_badge).should be_true }
  end

  it "issues one query per hop however many owners there are" do
    6.times { |index| user_with_badge("user #{index}") }

    queries = AssociationQueryCounter.selects { HtUser.includes(:ht_badge).select.to_a }
    queries.should eq(3)
  end

  it "applies the association scope to the target, like the lazy reader" do
    active_user, active_badge = user_with_badge("active", true)
    retired_user, _ = user_with_badge("retired", false)

    users = HtUser.includes(:active_badge).order(:id).select.index_by(&.id)
    users[active_user.id].active_badge.try(&.id).should eq(active_badge.id)
    users[retired_user.id].active_badge.should be_nil
    HtUser.find!(retired_user.id).active_badge.should be_nil
  end

  it "works with preload and inside nested includes" do
    user, badge = user_with_badge("nested")
    profile = HtProfile.where(ht_user_id: user.id).select.first

    HtUser.preload(:ht_badge).where(id: user.id).select.first.ht_badge.try(&.id).should eq(badge.id)

    profiles = HtProfile.includes(ht_user: :ht_badge).where(id: profile.id).select
    profiles.first.ht_user.try(&.ht_badge).try(&.id).should eq(badge.id)
  end

  it "reloads the through record from the database" do
    user, badge = user_with_badge("reload")
    loaded = HtUser.find!(user.id)
    loaded.ht_badge.try(&.id).should eq(badge.id)

    HtBadge.find!(badge.id).update!(label: "renamed")
    loaded.ht_badge.try(&.label).should eq("reload badge")
    loaded.reload_ht_badge.try(&.label).should eq("renamed")
  end
end
