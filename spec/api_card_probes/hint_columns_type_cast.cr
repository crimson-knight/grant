require "./probe_support"

def assert_database_value(value : T) forall T
  {% unless T <= Grant::Columns::Type %}
    {% raise "converted bind values must use Grant::Columns::Type" %}
  {% end %}
end

first = :score
assert_database_value(first.to_s)
