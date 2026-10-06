require "./probe_support"
require "../../src/grant/sharding"

class W6usNote < Grant::Base
  table :api_card_probe_w6_us_notes

  column id : Int64, primary: true
  column kind : String
end

class W6shThing < Grant::Base
  include Grant::Sharding::Model

  table :api_card_probe_w6_sh_things

  column id : Int64, primary: true
end

class AuditScopeModel < Grant::Base
  table :api_card_probe_audit_scope_models

  column id : Int64, primary: true
  column active : Bool

  scope :published, -> { where(active: true) }
end

class Invoice < Grant::Base
  table :api_card_probe_invoices

  column id : Int64, primary: true
  column tenant_id : Int64?
  column number : String
end

def assert_w6_note(value : T) forall T
  {% unless T == W6usNote %}
    {% raise "model construction must return the model" %}
  {% end %}
end

def assert_w6_builder(value : T) forall T
  {% unless T == Grant::Sharding::ShardedQuery(W6shThing) %}
    {% raise "on_shard must return the sharded model builder" %}
  {% end %}
end

def assert_invoice(value : T) forall T
  {% unless T == Invoice %}
    {% raise "model create! must return the model" %}
  {% end %}
end

assert_w6_note(W6usNote.new(kind: "z"))
assert_w6_builder(W6shThing.on_shard(:one))
AuditScopeModel.published.order(:id)
assert_invoice(Invoice.create!(tenant_id: nil, number: "Legacy"))
