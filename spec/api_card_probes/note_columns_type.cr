require "./probe_support"

def assert_column_values(value : T) forall T
  {% unless T == Array(Grant::Columns::Type) %}
    {% raise "Grant binds must use Array(Grant::Columns::Type)" %}
  {% end %}
end

values = [1_i64, "active"] of Grant::Columns::Type
assert_column_values(values)
