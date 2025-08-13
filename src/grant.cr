require "yaml"
require "db"
require "log"

module Grant
  Log = ::Log.for("grant")

  TIME_ZONE       = "UTC"
  DATETIME_FORMAT = "%F %X%z"

  alias ModelArgs = Hash(Symbol | String, Grant::Columns::Type)

  annotation Relationship; end
  annotation Column; end
  annotation Table; end
end

require "./adapter/base"
require "./grant/connection_registry"
require "./grant/base"
