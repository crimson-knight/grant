require "./probe_support"

alias GrantAPICardConnectionsEntry = NamedTuple(writer: Grant::Adapter::Base, reader: Grant::Adapter::Base) | Nil

def assert_registered_connection_lookup(value : T) forall T
  {% unless T == GrantAPICardConnectionsEntry %}
    {% raise "Grant::Connections[] must return an optional writer and reader tuple" %}
  {% end %}
end

def assert_writer_adapter(value : T) forall T
  {% unless T == Grant::Adapter::Base %}
    {% raise "a registered connection writer must be a Grant adapter" %}
  {% end %}
end

assert_registered_connection_lookup(Grant::Connections["pg"])
connection = Grant::Connections["pg"] || raise "pg connection missing"
assert_writer_adapter(connection[:writer])
