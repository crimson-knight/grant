require "./probe_support"

def assert_quoted_column(value : T) forall T
  {% unless T == String %}
    {% raise "Grant adapter quote must return String" %}
  {% end %}
end

adapter = Grant::Adapter::Sqlite.new(name: "api_card_probe", url: "sqlite3::memory:")
assert_quoted_column(adapter.quote("title"))
