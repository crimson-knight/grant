require "./probe_support"
require "../../src/grant/encryption"

class GrantAPICardEncryptedUser < Grant::Base
  table :api_card_probe_encrypted_users

  column id : Int64, primary: true
  encrypts :email, deterministic: true
end

alias EncryptedUserRows = Array(GrantAPICardEncryptedUser) | Grant::Collection(GrantAPICardEncryptedUser)

def assert_where_encrypted_returns_records(value : T) forall T
  {% unless T == EncryptedUserRows %}
    {% raise "where_encrypted must return an array or Grant collection" %}
  {% end %}
end

assert_where_encrypted_returns_records(GrantAPICardEncryptedUser.where_encrypted(email: "lookup@example.com"))
