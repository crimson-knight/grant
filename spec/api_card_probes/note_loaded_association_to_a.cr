require "./probe_support"

class GrantAPICardAssociationTarget < Grant::Base
  table :api_card_probe_association_targets

  column id : Int64, primary: true
  column association_owner_id : Int64?
end

class GrantAPICardAssociationOwner < Grant::Base
  table :api_card_probe_association_owners

  column id : Int64, primary: true

  has_many :association_targets, class_name: GrantAPICardAssociationTarget, foreign_key: :association_owner_id
end

def assert_loaded_association_clear_returns_collection(value : T) forall T
  {% unless T == Grant::LoadedAssociationCollection(GrantAPICardAssociationOwner, GrantAPICardAssociationTarget) %}
    {% raise "LoadedAssociationCollection#clear must return the loaded collection" %}
  {% end %}
end

def assert_loaded_association_to_a_returns_array(value : T) forall T
  {% unless T == Array(GrantAPICardProbeModels::Post) %}
    {% raise "LoadedAssociationCollection#to_a must return Array(Target)" %}
  {% end %}
end

loaded_posts = Grant::LoadedAssociationCollection(GrantAPICardProbeModels::User, GrantAPICardProbeModels::Post).new([] of GrantAPICardProbeModels::Post)
assert_loaded_association_to_a_returns_array(loaded_posts.to_a)
association_owner = GrantAPICardAssociationOwner.new
loaded_association = Grant::LoadedAssociationCollection(GrantAPICardAssociationOwner, GrantAPICardAssociationTarget).new([] of GrantAPICardAssociationTarget, association_owner, "association_owner_id")
assert_loaded_association_clear_returns_collection(loaded_association.clear)

def assert_mutable_association_clear_returns_collection(value : T) forall T
  {% unless T == Grant::AssociationCollection(GrantAPICardAssociationOwner, GrantAPICardAssociationTarget) %}
    {% raise "AssociationCollection#clear must return the association collection" %}
  {% end %}
end

assert_mutable_association_clear_returns_collection(GrantAPICardAssociationOwner.new.association_targets.clear)
