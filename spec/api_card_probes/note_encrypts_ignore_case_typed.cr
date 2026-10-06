require "./probe_support"
require "../../src/grant/encryption"

class GrantAPICardTypedIgnoreCase < Grant::Base
  table :api_card_probe_typed_ignore_case

  column id : Int64, primary: true
  encrypts email : String, deterministic: true, ignore_case: true
end

class GrantAPICardNullableTypedIgnoreCase < Grant::Base
  table :api_card_probe_nullable_typed_ignore_case

  column id : Int64, primary: true
  encrypts email : String?, deterministic: true, ignore_case: true
end

email_value : String? = GrantAPICardTypedIgnoreCase.new.email
nullable_email_value : String? = GrantAPICardNullableTypedIgnoreCase.new.email
