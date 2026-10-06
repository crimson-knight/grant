require "./probe_support"

class GrantAPICardProbePasswordAccount < Grant::Base
  table :api_card_probe_password_accounts

  column id : Int64, primary: true
  column password : String
end

def assert_set_attributes_returns_model(value : T) forall T
  {% unless T == GrantAPICardProbeModels::Post %}
    {% raise "set_attributes must return the same Post model" %}
  {% end %}
end

assert_set_attributes_returns_model(GrantAPICardProbeModels::Post.new(title: "old").set_attributes({"title" => "new"}))

password_account = GrantAPICardProbePasswordAccount.new
password_account.password = "next-pass"
