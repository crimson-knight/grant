require "json"
require "./base"

module Grant::Serializers
  class JSON < Base
    def serialize(object) : String
      object.to_json
    end

    def deserialize(string : String, klass) : Object
      klass.from_json(string)
    end
  end
end
