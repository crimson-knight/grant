require "./probe_support"

found_models = [] of Int64?

def assert_found_models_type(value : T) forall T
  {% unless T == Array(Int64?) %}
    {% raise "found_models must be Array(Int64?)" %}
  {% end %}
end

assert_found_models_type(found_models)
