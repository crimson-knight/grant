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

  # Raised when a table or index name is not in the schema.
  class UnknownSchemaObject < Error
    getter object_name : String

    def initialize(@object_name : String)
      super("no such table or index: #{@object_name}")
    end
  end
end
