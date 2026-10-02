require "./sti_behavior_models"

# Clean re-implementations of the behaviours covered by the archived
# `sti_specs/` (inheritance structure, query methods, becomes, type casting),
# adapted to the reimplemented STI API.
describe "Grant::STI behaviours (ported)" do
  before_all do
    setup_behavior_sti_tables
  end

  before_each do
    setup_behavior_sti_tables
    clear_behavior_sti_tables
  end

  describe "inheritance structure" do
    it "exposes STI class methods on root and subclasses" do
      BehaviorPersona.responds_to?(:inheritance_column).should be_true
      BehaviorPersona.responds_to?(:sti_root).should be_true
      BehaviorPersona.responds_to?(:find_sti_class).should be_true

      BehaviorAdminPersona.responds_to?(:inheritance_column).should be_true
      BehaviorAdminPersona.responds_to?(:sti_root).should be_true
      BehaviorAdminPersona.responds_to?(:find_sti_class).should be_true
    end

    it "reports the default inheritance column" do
      BehaviorPersona.inheritance_column.should eq "type"
      BehaviorAdminPersona.inheritance_column.should eq "type"
    end

    it "reports correct sti_name values" do
      BehaviorAdminPersona.sti_name.should eq "BehaviorAdminPersona"
      BehaviorMemberPersona.sti_name.should eq "BehaviorMemberPersona"
      BehaviorSuperAdminPersona.sti_name.should eq "BehaviorSuperAdminPersona"
    end

    it "inherits columns down the hierarchy" do
      # Subclass fields include the root's columns plus the subclass's own.
      BehaviorPersona.fields.should contain "name"
      BehaviorAdminPersona.fields.should contain "name"
      BehaviorAdminPersona.fields.should contain "access_level"
      BehaviorSuperAdminPersona.fields.should contain "access_level"
      BehaviorSuperAdminPersona.fields.should contain "god_mode"
    end
  end

  describe "class lookup" do
    it "finds registered STI classes by type name" do
      BehaviorPersona.find_sti_class("BehaviorPersona").should eq BehaviorPersona
      BehaviorPersona.find_sti_class("BehaviorAdminPersona").should eq BehaviorAdminPersona
      BehaviorPersona.find_sti_class("BehaviorMemberPersona").should eq BehaviorMemberPersona
    end

    it "raises SubclassNotFound for an unregistered class name" do
      expect_raises(Grant::STI::SubclassNotFound) do
        BehaviorPersona.find_sti_class("NonExistentPersona")
      end
    end
  end

  describe "descendant set for queries" do
    it "computes itself plus registered descendants" do
      BehaviorMemberPersona.sti_names_for_query.should eq ["BehaviorMemberPersona"]
      BehaviorAdminPersona.sti_names_for_query.sort.should eq ["BehaviorAdminPersona", "BehaviorSuperAdminPersona"]
    end
  end

  describe "becomes attribute fidelity" do
    it "copies all attributes including the role" do
      admin = BehaviorAdminPersona.new(name: "Test", role: "ops")
      member = admin.becomes(BehaviorMemberPersona)
      member.name.should eq "Test"
      member.role.should eq "ops"
    end

    it "sets the correct type column on the converted instance" do
      admin = BehaviorAdminPersona.new(name: "Test")
      member = admin.becomes(BehaviorMemberPersona)
      member.read_attribute("type").should eq "BehaviorMemberPersona"
    end

    it "copies nil/false attributes faithfully" do
      member = BehaviorMemberPersona.new(name: "Test", active: false)
      admin = member.becomes(BehaviorAdminPersona)
      # `active` is a shared-by-name? no — it is BehaviorMemberPersona-only, so the
      # BehaviorAdminPersona target has no such column. role (shared, nil) must copy.
      admin.role.should be_nil
      admin.name.should eq "Test"
    end
  end

  describe "type column immutability (ported)" do
    it "prevents direct type changes on persisted records" do
      admin = BehaviorAdminPersona.create!(name: "Test", access_level: 1)
      expect_raises(Grant::STI::ImmutableTypeError) do
        admin.write_attribute("type", "BehaviorMemberPersona")
      end
    end

    it "allows type changes on new records" do
      admin = BehaviorAdminPersona.new(name: "Test")
      admin.write_attribute("type", "BehaviorAdminPersona")
      admin.read_attribute("type").should eq "BehaviorAdminPersona"
    end
  end

  describe "unscoped bypasses the STI type filter" do
    it "returns every row regardless of type when called on a subclass" do
      BehaviorAdminPersona.create!(name: "Alice", access_level: 9)
      BehaviorMemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)

      # Scoped subclass query only sees its own type.
      BehaviorAdminPersona.all.to_a.size.should eq 1
      # `unscoped` drops the type filter (rows hydrate as BehaviorAdminPersona since
      # the subclass reader is used — this is the documented unscoped behaviour).
      BehaviorAdminPersona.unscoped.select.size.should eq 2
    end
  end
end
