# Records every statement the adapters run while a block runs (through the
# `Grant::Events::SQL` notification, which covers selects, inserts and the
# builder's bulk writes), so composite key specs can assert which predicates
# each persistence statement carries.
def capture_statements(& : ->) : Array(String)
  events = [] of Grant::Events::SQL
  handler = ->(event : Grant::Events::SQL) { events << event; nil }
  Grant::Notifications.subscribed(Grant::Events::SQL, handler) { yield }
  events.map(&.sql)
end

# The WHERE part of a recorded statement.
def where_part(sql : String) : String
  sql.split("WHERE", 2).last
end
