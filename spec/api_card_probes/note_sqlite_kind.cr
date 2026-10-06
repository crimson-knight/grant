require "./probe_support"

def assert_sqlite_error_kind(value : T) forall T
  {% unless T == Grant::Adapter::ErrorTranslator::Kind? %}
    {% raise "SQLite error_kind must return the shared nullable error kind" %}
  {% end %}
end

assert_sqlite_error_kind(Grant::Adapter::Sqlite.error_kind(19))
