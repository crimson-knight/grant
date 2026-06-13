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
require "./grant/sanitization"
require "./grant/connection_registry"
require "./grant/base"
require "./grant/sti"

# Large-table / high-scale query toolkit (index hints, IN chunking, streaming,
# tenant scoping). Required after Grant::Base is fully defined so the toolkit
# can reopen the builder and include the tenant-scoping macros into Base.
require "./grant/scale"
