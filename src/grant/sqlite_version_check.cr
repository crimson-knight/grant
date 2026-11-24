module Grant
  module SQLiteVersionCheck
    # SQLite version 3.24.0 = 3024000
    MINIMUM_VERSION = 3024000

    # Get SQLite version as a string. A program without the C engine (see
    # `Grant::SQLite3::Engine.libsqlite3_compiled_in?`) reports the version
    # Grant's engine follows.
    def self.version_string : String
      {% if Grant::SQLite3::Engine.has_constant?("LibSQLite3Engine") %}
        String.new(LibSQLite3.libversion)
      {% else %}
        Grant::SQLiteEngine::Query::Session::SQLITE_VERSION
      {% end %}
    end

    # Get SQLite version as an integer (e.g., 3024000 for 3.24.0)
    def self.version_number : Int32
      {% if Grant::SQLite3::Engine.has_constant?("LibSQLite3Engine") %}
        LibSQLite3.libversion_number
      {% else %}
        Grant::SQLiteEngine::Pager::WRITER_VERSION_NUMBER.to_i32
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
