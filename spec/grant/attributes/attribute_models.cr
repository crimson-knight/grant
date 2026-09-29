require "../../spec_helper"
require "../../../src/grant/encryption"

module AttributeSpecModels
  enum Level
    Low
    High
  end
end

{% begin %}
  {% adapter_literal = (env("CURRENT_ADAPTER") || "sqlite").id %}

  class AttrPost < Grant::Base
    connection {{ adapter_literal }}
    table attr_posts

    column id : Int64, primary: true
    column title : String?
    column views : Int32?
    column published : Bool?
    column level : AttributeSpecModels::Level?, column_type: "TEXT", converter: Grant::Converters::Enum(AttributeSpecModels::Level, String)
    column author_id : Int64?
    timestamps

    alias_attribute :name, :title
  end

  class AttrAccount < Grant::Base
    connection {{ adapter_literal }}
    table attr_accounts

    column id : Int64, primary: true
    column email : String?
    column password_digest : String?
    column api_token : String?
    encrypts :ssn
    filter_attributes :api_token
  end

  class AttrSlugged < Grant::Base
    connection {{ adapter_literal }}
    table attr_slugged

    column id : Int64, primary: true
    column slug : String?

    to_param :slug
  end

  class AttrPlain < Grant::Base
    connection {{ adapter_literal }}
    table attr_plains

    column id : Int64, primary: true
    column note : String
  end
{% end %}

Spec.before_suite do
  AttrPost.migrator.drop_and_create
  AttrAccount.migrator.drop_and_create
  AttrSlugged.migrator.drop_and_create
  AttrPlain.migrator.drop_and_create
end
