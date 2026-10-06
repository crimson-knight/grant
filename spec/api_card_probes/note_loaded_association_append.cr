require "./probe_support"

class GrantAPICardAssociationOwner < Grant::Base
  table :api_card_association_owners
  column id : Int64, primary: true
end

class GrantAPICardAssociationTarget < Grant::Base
  table :api_card_association_targets
  column id : Int64, primary: true
  column owner_id : Int64?
end

def assert_loaded_association_append(value : T) forall T
  {% unless T == Grant::LoadedAssociationCollection(GrantAPICardAssociationOwner, GrantAPICardAssociationTarget) %}
    {% raise "LoadedAssociationCollection#<< must return the same loaded collection" %}
  {% end %}
end

loaded = Grant::LoadedAssociationCollection(GrantAPICardAssociationOwner, GrantAPICardAssociationTarget).new([] of GrantAPICardAssociationTarget)
assert_loaded_association_append(loaded << GrantAPICardAssociationTarget.new)
