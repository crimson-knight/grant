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

  # :nodoc:
  #
  # SQLite calls this from C for every `REGEXP` it evaluates, so it hands all
  # work to `RegexpFunction.call`, which never lets an exception unwind into SQLite.
  REGEXP_FN = ->(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*) do
    RegexpFunction.call(context, argc, argv)
    nil
  end
end
