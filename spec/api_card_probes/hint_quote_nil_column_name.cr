require "./probe_support"

alias OptionalString = String | Nil

def quote_optional_column_name(adapter : Grant::Adapter::Base, column_name : OptionalString) : OptionalString
  if name = column_name
    adapter.quote(name)
  end
end

def assert_nullable_string(value : T) forall T
  {% unless T == OptionalString %}
    {% raise "narrowing an optional column name must return String or Nil" %}
  {% end %}
end

adapter = Grant::Adapter::Sqlite.new(name: "probe", url: ":memory:")
column_name : String? = "id"
assert_nullable_string(quote_optional_column_name(adapter, column_name))
