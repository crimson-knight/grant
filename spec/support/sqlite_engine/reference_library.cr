require "../../../src/grant/drivers/sqlite3/libsqlite3"

# The C SQLite Grant's engine is checked against: 3.51.0, built from the
# amalgamation pinned by hash in the engine's evidence. A comparison whose
# answer depends on the C library's version or platform (the STRICT type
# check of VIRTUAL columns, which the 3.45 and 3.46 Ubuntu ships skip, or the
# allocator-sized table hash that orders sqlite_stat1) runs only against it
# and is pending elsewhere.
module SQLiteEngineReferenceLibrary
  VERSION_NUMBER = 3_051_000

  def self.linked? : Bool
    Grant::LibSQLite3.libversion_number == VERSION_NUMBER
  end

  def self.linked_on_macos? : Bool
    {% if flag?(:darwin) %}
      linked?
    {% else %}
      false
    {% end %}
  end
end
