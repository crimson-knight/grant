# Exception thrown on invalid SQLite3 operations.
class Grant::SQLite3::Exception < ::Exception
  # The internal code associated with the failure.
  getter code : Int32

  # The most recent error of *connection*'s database.
  def self.new(connection : Connection) : self
    new(connection.engine_database)
  end

  # The most recent error of *database*.
  def initialize(database : Engine::Database)
    super(database.error_message)
    @code = database.error_code
  end
end
