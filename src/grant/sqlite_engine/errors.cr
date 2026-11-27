module Grant::SQLiteEngine
  # Base class of every error the engine raises.
  class Error < Exception
  end

  # Raised when a structural fact read from a database or WAL file fails a
  # check: a page number out of range, a cell outside its page, a cycle in a
  # chain, an inconsistent record header. Names the page (when one applies)
  # and the check that failed.
  class CorruptDatabase < Error
    getter page_number : UInt32?
    getter check : String

    def initialize(@check : String, @page_number : UInt32? = nil)
      if page_number = @page_number
        super("database disk image is malformed: page #{page_number}: #{@check}")
      else
        super("database disk image is malformed: #{@check}")
      end
    end
  end

  # Raised for well-formed SQL the engine does not implement yet, naming the
  # construct (for example a VIRTUAL generated column).
  class UnsupportedSQL < Error
    getter construct : String

    def initialize(@construct : String)
      super("unsupported SQL: #{@construct}")
    end
  end

  # Raised when a file system is asked to open a file on an operating
  # system it was not written for (`PosixFileSystem` on Windows, whose
  # files use POSIX advisory locks and mmap(2)). Names the one to use
  # there; `FileSystem.native` picks it.
  class UnsupportedPlatform < Error
    def initialize(file_system : String, platform : String, alternative : String)
      super("#{file_system} does not open files on #{platform}; use #{alternative} (Grant::SQLiteEngine::FileSystem.native)")
    end
  end

  # Raised when a table or index name is not in the schema.
  class UnknownSchemaObject < Error
    getter object_name : String

    def initialize(@object_name : String)
      super("no such table or index: #{@object_name}")
    end
  end
end

module Grant::SQLiteEngine
  # Raised when another connection holds a lock this one needs
  # (SQLITE_BUSY, https://www.sqlite.org/lockingv3.html).
  class Busy < Error
    # SQLITE_BUSY.
    EXTENDED_RESULT_CODE = 5

    def initialize(message : String = "database is locked")
      super(message)
    end

    # The extended result code C reports for this refusal
    # (https://www.sqlite.org/rescode.html#extrc).
    def extended_result_code : Int32
      EXTENDED_RESULT_CODE
    end
  end

  # Raised for a write to a database opened read-only.
  class ReadOnlyDatabase < Error
    def initialize(message : String = "attempt to write a readonly database")
      super(message)
    end
  end

  # Raised when a write would break a constraint: UNIQUE, PRIMARY KEY,
  # NOT NULL, or a STRICT column's datatype. Nothing the write started is
  # kept. A datatype refusal carries C's message as it stands ("cannot
  # store TEXT value in INT column t.a", "datatype mismatch"); the others
  # read "<KIND> constraint failed: <detail>".
  class ConstraintViolation < Error
    enum Kind
      Unique
      PrimaryKey
      NotNull
      Datatype
    end

    getter kind : Kind

    def initialize(@kind : Kind, detail : String)
      super(@kind.datatype? ? detail : "#{@kind.to_s.underscore.upcase.tr("_", " ")} constraint failed: #{detail}")
    end
  end

  # Raised when a write would pass one of the limits in `Limits`, naming it.
  class LimitExceeded < Error
    getter limit : String

    def initialize(@limit : String, detail : String)
      super("#{@limit} exceeded: #{detail}")
    end
  end

  # Raised by `create_table` and `create_index` when the name is taken, and
  # by schema writes that name reserved or missing objects.
  class SchemaError < Error
  end

  # Raised inside `Database#transaction` to end it with a rollback instead
  # of a commit; the transaction swallows it.
  class Rollback < Exception
  end
end
