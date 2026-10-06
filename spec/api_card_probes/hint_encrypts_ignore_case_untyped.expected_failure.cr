require "./probe_support"
require "../../src/grant/encryption"

class GrantAPICardUntypedIgnoreCase < Grant::Base
  table :api_card_probe_untyped_ignore_case

  column id : Int64, primary: true
  encrypts :email, deterministic: true, ignore_case: true
end
