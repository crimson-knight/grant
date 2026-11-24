module Grant::SQLiteEngine::Query
  # Makes a session's main database a copy of another database, as
  # sqlite3_backup_init, _step(-1) and _finish do: the pages are copied
  # under the source's read transaction, so the schema, the rows, the
  # indexes, sqlite_sequence and the header fields (user_version,
  # application_id, the schema cookie) all arrive, and the target's file is
  # one the C library reads as it is.
  module Backup
    # Copies the pages behind *source* over *target*'s main database.
    # Raises `SQLError` "destination database is in use" while *target* has
    # a transaction open (sqlite3_backup_init's check), and what
    # `Pager#replace_contents_with` raises.
    def self.copy(source : Pager, target : Session) : Nil
      target_pager = target.database.pager
      if target.in_transaction? || target_pager.in_write_transaction?
        raise SQLError.new("destination database is in use")
      end
      raise SQLError.new("source and destination must be distinct") if source.same?(target_pager)
      begin
        target_pager.replace_contents_with(source)
      ensure
        # sqlite3ResetAllSchemasOfConnection: the copied schema cookie may
        # equal the old one, so the session forgets the schema outright.
        target.reset_schema
      end
    end
  end
end
