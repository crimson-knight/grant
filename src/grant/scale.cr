# Large-table / high-scale query toolkit (Thread 2).
#
# Bundles the features for operating Grant against very large, often
# multi-tenant, tables:
#
# - Index hints with safe fallback (`use_index` / `force_index` / `ignore_index`)
# - Large-`IN`-list chunking (transparent, per-query `.in_chunks(of:)`)
# - Result streaming (`each_streamed`)
# - First-class tenant scoping (`multitenant` + `Grant::Tenant`)
#
# See `docs/large_tables.md` for the full playbook.
require "./scale/index_hints"
require "./scale/in_chunking"
require "./scale/streaming"
require "./scale/tenant"

abstract class Grant::Base
  include Grant::Scale::MultiTenancy
  extend Grant::Scale::Streaming::ClassMethods
end
