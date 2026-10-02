require "../../spec_helper"

# `has_many ... foreign_key:` is written both as a Symbol and as a bare name.
# Both must compile once the accessor is used, and both must scope the same.
{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class FkFormOwner < Grant::Base
    connection {{ adapter_literal }}
    table fk_form_owners
    column id : Int64, primary: true
    column label : String
    has_many :symbol_children, class_name: FkFormChild, foreign_key: :fk_form_owner_id
    has_many :bare_children, class_name: FkFormChild, foreign_key: fk_form_owner_id
  end

  class FkFormChild < Grant::Base
    connection {{ adapter_literal }}
    table fk_form_children
    column id : Int64, primary: true
    column fk_form_owner_id : Int64?
    column label : String
  end
{% end %}

describe "has_many foreign_key: spellings" do
  before_all do
    FkFormOwner.migrator.drop_and_create
    FkFormChild.migrator.drop_and_create
  end

  before_each do
    FkFormChild.clear
    FkFormOwner.clear
  end

  it "reads and writes through a Symbol and a bare foreign key alike" do
    owner = FkFormOwner.create!(label: "owner")
    other = FkFormOwner.create!(label: "other")
    FkFormChild.create!(label: "theirs", fk_form_owner_id: other.id)

    owner.symbol_children.create!(label: "by symbol")
    owner.bare_children.create!(label: "by bare name")

    owner.symbol_children.map(&.label).sort!.should eq(["by bare name", "by symbol"])
    owner.bare_children.map(&.label).sort!.should eq(["by bare name", "by symbol"])
  end
end
