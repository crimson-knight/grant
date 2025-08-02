require "json"
require "./base"

module Granite::Serializers
  class JSON < Base
    def serialize(object) : String
      object.to_json
    end

    def deserialize(string : String, klass) : Object
      klass.from_json(string)
    end
  end

  # JSONB uses the same serialization as JSON
  # The difference is handled at the database adapter level
  class JSONB < JSON
  end
end