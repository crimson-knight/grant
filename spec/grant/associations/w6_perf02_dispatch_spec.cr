require "../../spec_helper"
require "../../support/association_query_counter"

# Compile-memory batch PERF02: preloading and association mass assignment are
# reached per model (never through Grant::Base), and must behave exactly as the
# global registrations did.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class P02Team < Grant::Base
    connection {{ adapter_literal }}
    table p02_teams
    column id : Int64, primary: true
    column name : String
    has_many :p02_members, class_name: P02Member, foreign_key: :p02_team_id
    has_one :p02_badge, class_name: P02Badge, foreign_key: :p02_team_id
  end

  class P02Member < Grant::Base
    connection {{ adapter_literal }}
    table p02_members
    column id : Int64, primary: true
    column name : String
    column p02_team_id : Int64?
    belongs_to :p02_team, class_name: P02Team, foreign_key: :p02_team_id, optional: true
    has_many :p02_pins, class_name: P02Pin, foreign_key: :p02_member_id
  end

  class P02Pin < Grant::Base
    connection {{ adapter_literal }}
    table p02_pins
    column id : Int64, primary: true
    column label : String
    column p02_member_id : Int64?
  end

  class P02Badge < Grant::Base
    connection {{ adapter_literal }}
    table p02_badges
    column id : Int64, primary: true
    column label : String
    column p02_team_id : Int64?
  end

  # Never loaded through includes/preload/eager_load.
  class P02Loner < Grant::Base
    connection {{ adapter_literal }}
    table p02_loners
    column id : Int64, primary: true
    column name : String
    has_many :p02_loner_notes, class_name: P02LonerNote, foreign_key: :p02_loner_id
  end

  class P02LonerNote < Grant::Base
    connection {{ adapter_literal }}
    table p02_loner_notes
    column id : Int64, primary: true
    column body : String
    column p02_loner_id : Int64?
  end

  # An STI root that declares an association its subclass inherits.
  class P02Party < Grant::Base
    include Grant::STI
    connection {{ adapter_literal }}
    table p02_parties
    column id : Int64, primary: true
    column type : String
    column name : String
    has_many :p02_tags, class_name: P02Tag, foreign_key: :p02_party_id
  end

  class P02Guest < P02Party
  end

  class P02Tag < Grant::Base
    connection {{ adapter_literal }}
    table p02_tags
    column id : Int64, primary: true
    column label : String
    column p02_party_id : Int64?
  end
{% end %}

describe "association preload dispatch and writer dispatch" do
  before_all do
    {% for model in [P02Team, P02Member, P02Pin, P02Badge, P02Loner, P02LonerNote, P02Party, P02Tag] %}
      {{ model }}.migrator.drop_and_create
    {% end %}
  end

  before_each do
    {% for model in [P02Pin, P02Member, P02Badge, P02Team, P02LonerNote, P02Loner, P02Tag, P02Party] %}
      {{ model }}.clear
    {% end %}
  end

  describe "loader dispatch" do
    it "does not enable a model that is only queried" do
      P02Loner.create!(name: "plain")
      P02Loner.where(name: "plain").select.size.should eq(1)
      Grant::AssociationLoader.enabled?(P02Loner).should be_false
      Grant::AssociationLoader.enabled?(P02LonerNote).should be_false
    end

    it "enables a model and its association targets when it loads associations" do
      team = P02Team.create!(name: "t")
      member = P02Member.create!(name: "m", p02_team_id: team.id)
      P02Pin.create!(label: "pin", p02_member_id: member.id)

      teams = P02Team.includes(p02_members: :p02_pins).select
      Grant::AssociationLoader.enabled?(P02Team).should be_true
      Grant::AssociationLoader.enabled?(P02Member).should be_true

      AssociationQueryCounter.selects do
        teams.first.p02_members.first.not_nil!.p02_pins.size.should eq(1)
      end.should eq(0)
    end

    it "is idempotent" do
      Grant::AssociationLoader.enable(P02Team)
      Grant::AssociationLoader.enable(P02Team)
      Grant::AssociationLoader.enabled?(P02Team).should be_true
    end

    it "reports an unknown association name from an enabled model" do
      team = P02Team.create!(name: "t")
      Grant::AssociationLoader.enable(P02Team)
      Grant::AssociationLoader.batch_load([team] of Grant::Base, "nope").should be_false
      expect_raises(Grant::AssociationNotFoundError) do
        Grant::Preloader.new([team], :nope).call
      end
    end

    it "enables the model of a Preloader" do
      note_owner = P02Loner.create!(name: "owner")
      P02LonerNote.create!(body: "n", p02_loner_id: note_owner.id)
      owners = P02Loner.select.to_a
      Grant::Preloader.new(owners, :p02_loner_notes).call
      Grant::AssociationLoader.enabled?(P02Loner).should be_true
      owners.first.association_loaded?(:p02_loner_notes).should be_true
    end

    it "loads the associations of STI subclass records through the root's relation" do
      guest = P02Guest.create!(name: "guest")
      P02Tag.create!(label: "vip", p02_party_id: guest.id)

      parties = P02Party.includes(:p02_tags).select
      parties.first.should be_a(P02Guest)
      AssociationQueryCounter.selects do
        parties.first.p02_tags.size.should eq(1)
      end.should eq(0)
    end

    it "loads has_one and belongs_to through the per-model dispatcher" do
      team = P02Team.create!(name: "t")
      P02Badge.create!(label: "b", p02_team_id: team.id)
      P02Member.create!(name: "m", p02_team_id: team.id)

      P02Team.includes(:p02_badge).select.first.association_loaded?(:p02_badge).should be_true
      P02Member.includes(:p02_team).select.first.association_loaded?(:p02_team).should be_true
    end
  end

  describe "writer dispatch" do
    it "assigns belongs_to, has_one and has_many through mass assignment" do
      team = P02Team.new(name: "t")
      member = P02Member.new(name: "m", p02_team: team)
      member.p02_team.should be(team)

      badge = P02Badge.new(label: "b")
      team.assign_attributes({"p02_badge" => badge})
      team.p02_badge.should be(badge)

      first = P02Member.new(name: "1")
      second = P02Member.new(name: "2")
      team.assign_attributes({"p02_members" => [first, second]})
      team.p02_members.to_a.map(&.name).should eq(["1", "2"])
    end

    it "ignores a record of the wrong class" do
      team = P02Team.new(name: "t")
      member = P02Member.new(name: "m", p02_team: team)
      wrong = P02Badge.new(label: "b")
      member.assign_attributes({"p02_team" => wrong})
      member.p02_team.should be(team)
    end

    it "does not treat scalar columns as associations" do
      team = P02Team.new(name: "t")
      team.assign_attributes({"name" => "renamed"})
      team.name.should eq("renamed")
    end
  end
end
