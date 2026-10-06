require "./probe_support"

class GrantAPICardConfiguredUser < Grant::Base
  table :api_card_configured_users
  column id : Int64, primary: true

  configure_connection(failover_retry_attempts: 3)
end

def assert_connection_config_storage(value : T) forall T
  {% unless T == Hash(Symbol, String) %}
    {% raise "the no-argument connection_config getter must return Hash(Symbol, String)" %}
  {% end %}
end

assert_connection_config_storage(GrantAPICardConfiguredUser.connection_config)
