require "./sti_models"

# Headline acceptance spec: the type-safe personas/permissions use case.
describe "Grant::STI personas/permissions" do
  before_all do
    setup_sti_tables
  end

  before_each do
    clear_sti_tables
  end

  describe "type column auto-set on create" do
    it "stamps the concrete class name into the inheritance column" do
      admin = AdminPersona.create!(name: "Alice", role: "ops", access_level: 9)
      member = MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)
      root = Persona.create!(name: "Carol")

      admin.read_attribute("type").should eq "AdminPersona"
      member.read_attribute("type").should eq "MemberPersona"
      root.read_attribute("type").should eq "Persona"
    end

    it "auto-sets type for a deeply-nested subclass" do
      sa = SuperAdminPersona.create!(name: "Zed", access_level: 99, god_mode: true)
      sa.read_attribute("type").should eq "SuperAdminPersona"
    end
  end

  describe "table name inheritance" do
    it "shares the root's table across the whole hierarchy" do
      AdminPersona.table_name.should eq Persona.table_name
      MemberPersona.table_name.should eq Persona.table_name
      SuperAdminPersona.table_name.should eq Persona.table_name
    end
  end

  describe "root / subclass detection" do
    it "computes the STI root for every level" do
      Persona.sti_root.should eq Persona
      AdminPersona.sti_root.should eq Persona
      SuperAdminPersona.sti_root.should eq Persona
    end

    it "identifies subclasses correctly" do
      Persona.sti_subclass?.should be_false
      AdminPersona.sti_subclass?.should be_true
      SuperAdminPersona.sti_subclass?.should be_true
    end
  end

  describe "subclass query filtering (incl. descendants)" do
    it "filters a subclass query to its own type" do
      AdminPersona.create!(name: "Alice", access_level: 9)
      MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)

      members = MemberPersona.all.to_a
      members.map(&.name).should eq ["Bob"]
      members.all?(&.is_a?(MemberPersona)).should be_true
    end

    it "includes registered descendants (AdminPersona.all returns SuperAdmins too)" do
      AdminPersona.create!(name: "Alice", access_level: 9)
      SuperAdminPersona.create!(name: "Zed", access_level: 99, god_mode: true)
      MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)

      admins = AdminPersona.all.to_a
      admins.map(&.name).sort.should eq ["Alice", "Zed"]
      admins.map(&.class.name).sort.should eq ["AdminPersona", "SuperAdminPersona"]
    end

    it "applies no type filter on a root query" do
      AdminPersona.create!(name: "Alice", access_level: 9)
      MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)
      Persona.create!(name: "Carol")

      Persona.all.to_a.size.should eq 3
    end
  end

  describe "base-class queries return correctly-typed subclass instances" do
    it "instantiates each row as its concrete subclass with working behaviour" do
      AdminPersona.create!(name: "Alice", access_level: 9)
      MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)
      Persona.create!(name: "Carol")

      by_name = Persona.all.to_a.to_h { |p| {p.name, p} }
      by_name["Alice"].class.should eq AdminPersona
      by_name["Bob"].class.should eq MemberPersona
      by_name["Carol"].class.should eq Persona

      # The subclass methods dispatch correctly on base-loaded instances.
      # (AdminPersona#permissions is independent of subclass-only columns.)
      by_name["Alice"].permissions.should eq ["read", "write", "admin"]
      by_name["Carol"].permissions.should eq ["read"]
      # MemberPersona#permissions consults the subclass-only `active` column,
      # which a base-class SELECT does not fetch (documented limitation), so it
      # falls back to the base permission set. A subclass query hydrates it.
      by_name["Bob"].permissions.should eq ["read"]
      MemberPersona.find_by!(name: "Bob").as(MemberPersona).permissions.should eq ["read", "comment"]
    end

    it "populates shared columns but leaves subclass-only columns nil (documented limitation)" do
      MemberPersona.create!(name: "Eve", membership_tier: "silver", active: false)

      via_base = Persona.all.to_a.find { |p| p.name == "Eve" }.as(MemberPersona)
      via_subclass = MemberPersona.find_by!(name: "Eve").as(MemberPersona)

      # Shared column populated via base query.
      via_base.name.should eq "Eve"
      # Subclass-only column is NOT selected by a base-class query.
      via_base.membership_tier.should be_nil
      # The dedicated subclass query hydrates everything.
      via_subclass.membership_tier.should eq "silver"
    end
  end

  describe "find returns the correct subclass" do
    it "returns the concrete subclass from a root find" do
      admin = AdminPersona.create!(name: "Alice", access_level: 9)
      found = Persona.find(admin.id)
      found.should be_a AdminPersona
    end

    it "restricts a subclass find to its own type" do
      admin = AdminPersona.create!(name: "Alice", access_level: 9)
      member = MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)

      AdminPersona.find(admin.id).should be_a AdminPersona
      AdminPersona.find(member.id).should be_nil
    end
  end

  describe "#becomes" do
    it "converts in memory, preserving attributes, without touching the DB" do
      admin = AdminPersona.create!(name: "Alice", role: "ops", access_level: 9)

      member = admin.becomes(MemberPersona)
      member.should be_a MemberPersona
      member.name.should eq "Alice"
      member.role.should eq "ops"
      member.read_attribute("type").should eq "MemberPersona"

      # The database row is untouched.
      Persona.find!(admin.id).class.should eq AdminPersona
    end

    it "preserves the primary key and persisted state" do
      admin = AdminPersona.create!(name: "Alice", access_level: 9)
      member = admin.becomes(MemberPersona)
      member.id.should eq admin.id
      member.new_record?.should be_false
    end
  end

  describe "#becomes!" do
    it "persists the new type to the database" do
      admin = AdminPersona.create!(name: "Alice", access_level: 9)
      admin.becomes!(MemberPersona)

      reloaded = Persona.find!(admin.id)
      reloaded.class.should eq MemberPersona
      reloaded.read_attribute("type").should eq "MemberPersona"
    end
  end

  describe "immutable inheritance column" do
    it "raises when writing the type column on a persisted record" do
      admin = AdminPersona.create!(name: "Alice", access_level: 9)
      expect_raises(Grant::STI::ImmutableTypeError) do
        admin.write_attribute("type", "MemberPersona")
      end
    end

    it "allows setting the type column on a new record" do
      fresh = AdminPersona.new(name: "Dave")
      fresh.write_attribute("type", "AdminPersona")
      fresh.read_attribute("type").should eq "AdminPersona"
    end
  end

  describe "JSON round-trip of a subclass instance" do
    it "serializes and deserializes a subclass back to the same class" do
      member = MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)
      json = member.to_json

      restored = MemberPersona.from_json(json)
      restored.should be_a MemberPersona
      restored.name.should eq "Bob"
      restored.membership_tier.should eq "gold"
      restored.read_attribute("type").should eq "MemberPersona"
    end
  end

  describe "YAML round-trip of a subclass instance" do
    it "serializes and deserializes a subclass back to the same class" do
      member = MemberPersona.create!(name: "Bob", membership_tier: "gold", active: true)
      yaml = member.to_yaml

      restored = MemberPersona.from_yaml(yaml)
      restored.should be_a MemberPersona
      restored.name.should eq "Bob"
      restored.membership_tier.should eq "gold"
    end

    it "round-trips a deeply-nested (2+ level) subclass" do
      sa = SuperAdminPersona.create!(name: "Zed", access_level: 99, god_mode: true)
      restored = SuperAdminPersona.from_yaml(sa.to_yaml)
      restored.should be_a SuperAdminPersona
      restored.name.should eq "Zed"
      restored.access_level.should eq 99
    end
  end

  describe "custom inheritance column" do
    it "honours a custom inheritance column name" do
      Document.inheritance_column.should eq "doc_type"
      contract = Contract.create!(title: "NDA", counterparty: "Acme")
      contract.read_attribute("doc_type").should eq "Contract"
    end

    it "filters subclass queries on the custom column" do
      Contract.create!(title: "NDA", counterparty: "Acme")
      Report.create!(title: "Q3", summary: "good")

      Contract.all.to_a.map(&.title).should eq ["NDA"]
      Document.all.to_a.size.should eq 2
    end
  end
end
