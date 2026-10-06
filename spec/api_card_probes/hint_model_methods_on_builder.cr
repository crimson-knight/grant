require "./probe_support"

class EverywhereScopedRecord < Grant::Base
  table :api_card_probe_everywhere_scoped_records

  column id : Int64, primary: true
  column title : String
end

alias OptionalEverywhereScopedRecord = EverywhereScopedRecord | Nil

def assert_scoped_record(value : T) forall T
  {% unless T == EverywhereScopedRecord %}
    {% raise "a Grant builder first! call must return the model" %}
  {% end %}
end

def assert_optional_scoped_record(value : T) forall T
  {% unless T == OptionalEverywhereScopedRecord %}
    {% raise "a Grant builder first call must return the model or Nil" %}
  {% end %}
end

assert_scoped_record(EverywhereScopedRecord.unscoped.where(title: "visible one").first!)
assert_optional_scoped_record(EverywhereScopedRecord.where(title: "visible one").first)
