require "yaml"
require "db"
require "log"

module Grant
  Log = ::Log.for("grant")

  # Base class for domain errors raised by Grant's public behavior.
  class ErrorBase < ::Exception
    # A secondary cleanup error attached while preserving the original failure.
    # :nodoc:
    property cleanup_error : ::Exception?
  end

  TIME_ZONE       = "UTC"
  DATETIME_FORMAT = "%F %X.%6N%z"

  alias ModelArgs = Hash(Symbol | String, Grant::Columns::Type)

  annotation Relationship; end
  annotation Column; end
  annotation Table; end
end

require "./grant/notifications"
require "./adapter/base"
require "./grant/sanitization"
require "./grant/connection_registry"
require "./grant/result"
require "./grant/connection"
require "./grant/connection_manager"
require "./grant/target"
require "./grant/base"
require "./grant/sti"
require "./grant/schema/introspection"
require "./grant/schema/schema_statements"
require "./grant/schema/constraint_catalog"
require "./grant/schema/model_indexes"

# Large-table / high-scale query toolkit (index hints, IN chunking, streaming,
# tenant scoping). Required after Grant::Base is fully defined so the toolkit
# can reopen the builder and include the tenant-scoping macros into Base.
require "./grant/scale"
require "./grant/middleware/query_cache"
require "./grant/database_configurations"
require "./grant/parity"
