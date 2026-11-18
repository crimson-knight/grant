require "db"

module Grant
end

require "./sqlite3/**"

module Grant::SQLite3
  DATE_FORMAT_SUBSECOND = "%F %H:%M:%S.%L"
  DATE_FORMAT_SECOND    = "%F %H:%M:%S"

  alias Any = DB::Any | Int16 | Int8 | UInt32 | UInt16 | UInt8

  # :nodoc:
  TIME_ZONE = Time::Location::UTC
end
