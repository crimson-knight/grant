require "./probe_support"

class ScopedAssociationModifierProbe < Grant::Base
  table :api_card_probe_scoped_association_modifier_probes

  column id : Int64, primary: true
  column active : Bool

  scope :active_limited, -> { where(active: true).order(id: :desc).limit(1) }
end

def assert_scoped_builder(value : T) forall T
  {% unless T == ScopedAssociationModifierProbe::BuildNamedScopeRelation %}
    {% raise "a scope block must return its Grant builder" %}
  {% end %}
end

assert_scoped_builder(ScopedAssociationModifierProbe.active_limited)
