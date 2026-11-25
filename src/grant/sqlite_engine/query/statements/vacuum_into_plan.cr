module Grant::SQLiteEngine::Query
  # VACUUM [schema] INTO filename (lang_vacuum.html, sqlite3RunVacuum): the
  # named database is copied into a new database file. The filename is any
  # expression without column references, parameters included; the file
  # must be absent or empty. The copy is taken page for page from the
  # current snapshot, in rollback-journal mode whatever the source's mode.
  class VacuumIntoPlan < StatementPlan
    # SQLITE_IOERR, SQLITE_CANTOPEN and SQLITE_NOTADB.
    IO_ERROR_CODE       = 10
    CANNOT_OPEN_CODE    = 14
    NOT_A_DATABASE_CODE = 26

    def initialize(@session : Session, @statement : SQL::Vacuum, @into : SQL::Expression)
      @program = RowProgram.new(@session, RowProgram.columns([@into]), [] of PseudoTable)
      # An unknown schema name is refused when the statement is prepared.
      source_database
    end

    # The plan of *statement* when it has an INTO clause.
    def self.for(session : Session, statement : SQL::Vacuum) : VacuumIntoPlan?
      into = statement.into
      into ? new(session, statement, into) : nil
    end

    def run(list_of_parameters : Array(Value)) : Array(Array(Value))
      row = @program.evaluate(list_of_parameters)
      file = row ? row[0] : nil
      raise SQLError.new("non-text filename") unless file.is_a?(String)
      raise SQLError.new("cannot VACUUM from within a transaction") if @session.in_transaction?
      source = source_database
      # An empty name is a private temporary database, gone when the
      # statement ends; so is the copy held in ":memory:".
      return NO_ROWS if file.empty? || file == ":memory:"
      write_copy(source.pager, file)
      NO_ROWS
    end

    private def source_database : Database
      schema = @statement.schema
      return @session.database unless schema
      @session.existing_database_named(schema.value) || raise SQLError.new("unknown database #{schema.value}")
    end

    # Opens *file* as C attaches it (a file that is no database is refused
    # there), refuses one that already holds anything, and copies.
    private def write_copy(source : Pager, file : String) : Nil
      # unixFileSize reports a one-byte file as empty, so C writes over it.
      File.open(file, "r+", &.truncate) if File.exists?(file) && File.size(file) == 1
      target = begin
        Pager.open_read_write(FileSystem.native, file)
      rescue File::Error
        raise SQLError.new("unable to open database: #{file}", CANNOT_OPEN_CODE)
      rescue CorruptDatabase
        raise SQLError.new("file is not a database", NOT_A_DATABASE_CODE)
      end
      begin
        raise SQLError.new("output file already exists") if File.size(file) > 0
        target.replace_contents_with(source)
        target.leave_wal_mode
      rescue File::Error
        raise SQLError.new("disk I/O error", IO_ERROR_CODE)
      ensure
        target.close
      end
    end
  end
end
