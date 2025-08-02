module Granite::Serializers
  abstract class Base
    abstract def serialize(object) : String
    abstract def deserialize(string : String, klass) : Object
  end
end