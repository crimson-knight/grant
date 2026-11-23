# Add missing libversion bindings to LibSQLite3
{% unless flag?(:grant_without_libsqlite3) %}
  module Grant
    lib LibSQLite3
      fun libversion = sqlite3_libversion : UInt8*
      fun libversion_number = sqlite3_libversion_number : Int32
    end
  end
{% end %}

module Grant
  module SQLiteVersionCheck
    # SQLite version 3.24.0 = 3024000
    MINIMUM_VERSION = 3024000

    # Get SQLite version as a string. A program built with
    # -Dgrant_without_libsqlite3 reports the version Grant's engine follows.
    def self.version_string : String
      {% if flag?(:grant_without_libsqlite3) %}
        Grant::SQLiteEngine::Query::Session::SQLITE_VERSION
      {% else %}
        String.new(LibSQLite3.libversion)
      {% end %}
    end

    # Get SQLite version as an integer (e.g., 3024000 for 3.24.0)
    def self.version_number : Int32
      {% if flag?(:grant_without_libsqlite3) %}
        Grant::SQLiteEngine::Pager::WRITER_VERSION_NUMBER.to_i32
      {% else %}
        LibSQLite3.libversion_number
      {% end %}
    end

    # Check if SQLite version meets minimum requirements
    def self.supported? : Bool
      version_number >= MINIMUM_VERSION
    end

    # Raise an error if SQLite version is too old
    def self.ensure_supported!
      unless supported?
        raise "SQLite version #{version_string} is not supported. Grant requires SQLite 3.24.0 or later for proper ON CONFLICT support. Current version number: #{version_number}, required: #{MINIMUM_VERSION}"
      end
    end
  end
end
