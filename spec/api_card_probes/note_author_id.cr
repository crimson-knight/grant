require "./probe_support"

def assert_author_id(value : T) forall T
  {% unless T == GrantAPICardProbeModels::NullableInt64 %}
    {% raise "Post.author_id must be nilable Int64" %}
  {% end %}
end

def assert_author_id_bang(value : T) forall T
  {% unless T == Int64 %}
    {% raise "Post.author_id! must be Int64" %}
  {% end %}
end

assert_author_id(GrantAPICardProbeModels::Post.new.author_id)
assert_author_id_bang(GrantAPICardProbeModels::Post.new.author_id!)
