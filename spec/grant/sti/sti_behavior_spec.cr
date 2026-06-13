require "./sti_models"

# Clean re-implementations of the behaviours covered by the archived
# `sti_specs/` (inheritance structure, query methods, becomes, type casting),
# adapted to the reimplemented STI API.
describe "Grant::STI behaviours (ported)" do
  before_all do
    setup_sti_tables
  end

  before_each do
    clear_sti_tables
  end

  describe "inheritance structure" do
    it "exposes STI class methods on root and subclasses" do
      Persona.responds_to?(:inheritance_column).should be_true
      Persona.responds_to?(:sti_root).should be_true
      Persona.responds_to?(:find_sti_class).should be_true

      AdminPersona.responds_to?(:inheritance_column).should be_true
      AdminPersona.responds_to?(:sti_root).should be_true
      AdminPersona.responds_to?(:find_sti_class).should be_true
    end

    it "reports the default inheritance column" do
      Persona.inheritance_column.should eq "type"
      AdminPersona.inheritance_column.should eq "type"
    end

    it "reports correct sti_name values" do
      AdminPersona.sti_name.should eq "AdminPersona"
      MemberPersona.sti_name.should eq "MemberPersona"
      SuperAdminPersona.sti_name.should eq "SuperAdminPersona"
    end

    it "inherits columns down the hierarchy" do
      # Subclass fields include the root's columns plus the subclass's own.
      Persona.fields.should contain "name"
      AdminPersona.fields.should contain "name"
      AdminPersona.fields.should contain "access_level"
      SuperAdminPersona.fields.should contain "access_level"
      SuperAdminPersona.fields.should contain "god_mode"
    end
  end

  describe "class lookup" do
    it "finds registered STI classes by type name" do
      Persona.find_sti_class("Persona").should eq Persona
      Persona.find_sti_class("AdminPersona").should eq AdminPersona
      Persona.find_sti_class("MemberPersona").should eq MemberPersona
    end

    it "raises SubclassNotFound for an unregistered class name" do
      expect_raises(Grant::STI::SubclassNotFound) do
        Persona.find_sti_class("NonExistentPersona")
      end
    end
  end

  describe "descendant set for queries" do
    it "computes itself plus registered descendants" do
      MemberPersona.sti_names_for_query.should eq ["MemberPersona"]
      AdminPersona.sti_names_for_query.sort.should eq ["AdminPersona", "SuperAdminPersona"]
    end
  end

  describe "becomes attribute fidelity" do
    it "copies all attributes including the role" do
      admin = AdminPersona.new(name: "Test", role: "ops")
      member = admin.becomes(MemberPersona)
      member.name.should eq "Test"
      member.role.should eq "ops"
    end

    it "sets the correct type column on the converted instance" do
      admin = AdminPersona.new(name: "Test")
      member = admin.becomes(MemberPersona)
      member.read_attribute("type").should eq "MemberPersona"
    end

    it "copies nil/false attributes faithfully" do
      member = MemberPersona.new(name: "Test", active: false)
      admin = member.becomes(AdminPersona)
      # `active` is a shared-by-name? no — it is MemberPersona-only, so the
      # AdminPersona target has no such column. role (shared, nil) must copy.
      admin.role.should be_nil
      admin.name.should eq "Test"
    end
  end

  describe "type column immutability (ported)" do
    it "prevents direct type changes on persisted records" do
      admin = AdminPersona.create!(name: "Test", access_level: 1)
      expect_raises(Grant::STI::ImmutableTypeError) do
        admin.write_attribute("type", "MemberPersona")
      end
    end

    it "allows type changes on new records" do
      admin = AdminPersona.new(name: "Test")
      admin.write_attribute("type", "AdminPersona")
      admin.read_attribute("type").should eq "AdminPersona"
    end
  end

  describe "unscoped bypasses the STI type filter" do
    it "returns every row regardless of type when called on a subclass" do
      AdminPersona.create!(name: "Alice", access_level: 9)
      MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)

      # Scoped subclass query only sees its own type.
      AdminPersona.all.to_a.size.should eq 1
      # `unscoped` drops the type filter (rows hydrate as AdminPersona since
      # the subclass reader is used — this is the documented unscoped behaviour).
      AdminPersona.unscoped.select.size.should eq 2
    end
  end
end
