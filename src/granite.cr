require "yaml"
require "db"
require "log"

module Granite
  Log = ::Log.for("granite")

  TIME_ZONE       = "UTC"
  DATETIME_FORMAT = "%F %X%z"

  alias ModelArgs = Hash(Symbol | String, Granite::Columns::Type)

  annotation Relationship; end
  annotation Column; end
  annotation Table; end
end

require "./granite/connection_registry"
require "./granite/base"
