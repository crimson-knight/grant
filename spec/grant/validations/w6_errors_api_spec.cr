require "../../spec_helper"

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class W6EaMember < Grant::Base
    connection {{ adapter_literal }}
    table w6_ea_members

    column id : Int64, primary: true
    column name : String?
    column role : String?
    column handle : String?
    column slug : String?
    column code : String?
    column age : Int32?
    column room : Int32?
    column zone : String?

    validates_length_of :name, minimum: 3, maximum: 8
    validates_length_of :zone, in: 2..4
    validates_inclusion_of :role, in: ["admin", "user"]
    validates_exclusion_of :handle, in: ["root", "system"]
    validates_uniqueness_of :slug, scope: :room, allow_nil: true
    validates_format_of :code, with: /\A\d+\z/, allow_nil: true
    validates_comparison_of :age, greater_than_or_equal_to: 18, less_than: 100, allow_nil: true
  end

  class W6EaTeam < Grant::Base
    connection {{ adapter_literal }}
    table w6_ea_teams

    column id : Int64, primary: true
    column title : String?

    has_many :w6_ea_players, class_name: W6EaPlayer, foreign_key: :w6_ea_team_id, autosave: true, index_errors: true
  end

  class W6EaPlayer < Grant::Base
    connection {{ adapter_literal }}
    table w6_ea_players

    column id : Int64, primary: true
    column w6_ea_team_id : Int64?
    column nick : String?

    validates_uniqueness_of :nick, scope: :w6_ea_team_id
    belongs_to :w6_ea_team, class_name: W6EaTeam, foreign_key: w6_ea_team_id : Int64?
  end
{% end %}

private def w6_member(**attributes)
  member = W6EaMember.new(**attributes)
  member.valid?
  member
end

describe "Grant::Errors (ActiveRecord API)" do
  before_all do
    W6EaMember.migrator.drop_and_create
    W6EaTeam.migrator.drop_and_create
    W6EaPlayer.migrator.drop_and_create
  end

  before_each do
    W6EaMember.clear
    W6EaPlayer.clear
    W6EaTeam.clear
  end

  describe "to_json" do
    it "emits the ActiveRecord shape: attribute names mapped to message arrays" do
      member = w6_member(name: "ab", role: "guest", zone: "x")
      member.errors.to_json.should eq(
        %({"name":["is too short (minimum is 3 characters)"],"zone":["is too short (minimum is 2 characters)"],"role":["is not included in the list"]})
      )
    end

    it "nests inside a larger document the way ActiveRecord renders errors" do
      member = w6_member(name: "abc", role: "guest", zone: "xyz")
      document = JSON.build { |json| json.object { json.field "errors", member.errors } }
      document.should eq(%({"errors":{"role":["is not included in the list"]}}))
    end

    it "keeps the older list shape as to_json_list" do
      member = w6_member(name: "abcdefghi", role: "user", zone: "xyz")
      member.errors.to_json_list.should eq(%([{"field":"name","message":"is too long (maximum is 8 characters)"}]))
    end

    it "is {} for a valid record" do
      member = w6_member(name: "abc", role: "user", zone: "xyz")
      member.errors.to_json.should eq("{}")
    end
  end

  describe "details" do
    it "keeps String keys (a Symbol cannot be made at run time) and offers Symbol lookup" do
      member = w6_member(name: "ab", role: "guest", zone: "xyz")
      member.errors.details.keys.should eq(["name", "role"])
      member.errors.details_for(:name).should eq([{:error => :too_short, :count => 3}])
      member.errors.details_for("name").should eq(member.errors.details["name"])
      member.errors.details_for(:zone).should be_empty
    end

    it "types every entry as Hash(Symbol, Grant::Error::Value)" do
      member = w6_member(name: "ab", role: "guest", zone: "xyz")
      entry = member.errors.details["role"].first
      entry.should be_a(Hash(Symbol, Grant::Error::Value))
      entry[:error].should eq(:inclusion)
    end

    it "carries value: for inclusion, exclusion, format and comparison" do
      member = w6_member(name: "abc", role: "guest", handle: "root", code: "x1", age: 12, zone: "xyz")
      member.errors.details_for(:role).should eq([{:error => :inclusion, :value => "guest"}])
      member.errors.details_for(:handle).should eq([{:error => :exclusion, :value => "root"}])
      member.errors.details_for(:code).should eq([{:error => :invalid, :value => "x1"}])
      member.errors.details_for(:age).should eq([{:error => :greater_than_or_equal_to, :count => 18, :value => 12}])
    end

    it "carries value: for uniqueness" do
      W6EaMember.create!(name: "abc", role: "user", zone: "xyz", slug: "taken", room: 1)
      member = w6_member(name: "abc", role: "user", zone: "xyz", slug: "taken", room: 1)
      member.errors.details_for(:slug).should eq([{:error => :taken, :value => "taken"}])
      member.errors[:slug].should eq(["has already been taken"])
      w6_member(name: "abc", role: "user", zone: "xyz", slug: "taken", room: 2).errors.should be_empty
    end

    it "reports the bound that failed for a combined min+max length" do
      too_short = w6_member(name: "ab", role: "user", zone: "xyz")
      too_short.errors.details_for(:name).should eq([{:error => :too_short, :count => 3}])
      too_long = w6_member(name: "abcdefghi", role: "user", zone: "xyz")
      too_long.errors.details_for(:name).should eq([{:error => :too_long, :count => 8}])
      w6_member(name: "abcd", role: "user", zone: "xyz").errors.should be_empty
    end

    it "uses the range ends as the bounds of in:" do
      w6_member(name: "abc", role: "user", zone: "x").errors.details_for(:zone).should eq([{:error => :too_short, :count => 2}])
      w6_member(name: "abc", role: "user", zone: "xxxxx").errors.details_for(:zone).should eq([{:error => :too_long, :count => 4}])
    end

    it "gives each failed comparison its own error" do
      member = w6_member(name: "abc", role: "user", zone: "xyz", age: 150)
      member.errors.details_for(:age).should eq([{:error => :less_than, :count => 100, :value => 150}])
      member.errors[:age].should eq(["must be less than 100"])
    end
  end

  describe "lookup helpers" do
    it "answers of_type, where, include?, attribute_names and group_by_attribute" do
      member = w6_member(name: "ab", role: "guest", zone: "xyz")
      member.errors.of_type(:name, :too_short).should be_true
      member.errors.of_type(:name, :too_short, count: 3).should be_true
      member.errors.of_type(:name, :too_short, count: 4).should be_false
      member.errors.of_type?(:role, :inclusion).should be_true
      member.errors.where(:name, :too_short, count: 3).size.should eq(1)
      member.errors.include?(:name).should be_true
      member.errors.include?(:age).should be_false
      member.errors.attribute_names.should eq(["name", "role"])
      member.errors.group_by_attribute.keys.should eq(["name", "role"])
      member.errors.has_message?(:role, "is not included in the list").should be_true
    end

    it "merges another collection as copies and reports full messages" do
      first = w6_member(name: "ab", role: "user", zone: "xyz")
      second = w6_member(name: "abc", role: "guest", zone: "xyz")
      first.errors.merge!(second.errors)
      first.errors.full_messages.should eq(["Name is too short (minimum is 3 characters)", "Role is not included in the list"])
      first.errors.to_hash(full_messages: true).keys.should eq(["name", "role"])
      first.errors.objects.last.should_not be(second.errors.objects.first)
    end

    it "raises Grant::RecordInvalid whose record exposes the same errors" do
      member = W6EaMember.new(name: "ab", role: "user", zone: "xyz")
      ex = expect_raises(Grant::RecordInvalid, "Validation failed: Name is too short (minimum is 3 characters)") { member.save! }
      ex.record.errors.to_json.should eq(%({"name":["is too short (minimum is 3 characters)"]}))
    end
  end

  describe "uniqueness with has_many index_errors" do
    it "keys the child's uniqueness error by its position" do
      team = W6EaTeam.create!(title: "A")
      W6EaPlayer.create!(nick: "dup", w6_ea_team_id: team.id)
      team = W6EaTeam.find!(team.id)
      team.w6_ea_players.build(nick: "fresh")
      team.w6_ea_players.build(nick: "dup")
      team.valid?.should be_false
      team.errors["w6_ea_players[1].nick"].should eq(["has already been taken"])
      team.errors["w6_ea_players.nick"].should be_empty
      team.errors.details["w6_ea_players[1].nick"].should eq([{:error => :taken, :value => "dup"}])
      team.errors.to_json.should eq(%({"w6_ea_players[1].nick":["has already been taken"]}))
    end
  end
end
