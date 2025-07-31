module Granite
  module SQLiteVersionCheck
    # SQLite version 3.24.0 = 3024000
    MINIMUM_VERSION = 3024000
    
    # Get SQLite version as a string
    def self.version_string : String
      String.new(LibSQLite3.libversion)
    end
    
    # Get SQLite version as an integer (e.g., 3024000 for 3.24.0)
    def self.version_number : Int32
      LibSQLite3.libversion_number
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