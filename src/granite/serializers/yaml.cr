require "yaml"
require "./base"

module Granite::Serializers
  class YAML < Base
    def serialize(object) : String
      object.to_yaml
    end

    def deserialize(string : String, klass) : Object
      klass.from_yaml(string)
    end
  end
end