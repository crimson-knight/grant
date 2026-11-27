require "../../../src/grant/sqlite_engine"

# A file system held in memory that records every sync the engine makes:
# which file it was (database, journal or WAL), the mode it asked for, and
# the phase the spec had named when it happened.
class SQLiteEngineCountingFileSystem < Grant::SQLiteEngine::FileSystem
  enum FileKind
    Database
    Journal
    Wal
    WalIndex
  end

  record SyncCall, kind : FileKind, mode : Grant::SQLiteEngine::SyncMode, phase : String do
    def to_s(io : IO) : Nil
      io << phase << ' ' << kind.to_s.downcase << ' ' << mode.to_s.downcase
    end
  end

  record WritebackRequest, kind : FileKind, offset : Int64, length : Int64, written_size : Int64

  getter list_of_sync_calls = [] of SyncCall
  # Every `DatabaseFile#start_writeback` request, with the file's size when
  # it was made.
  getter list_of_writeback_requests = [] of WritebackRequest
  # The offset of every read of the database file (not the journal or
  # WAL).
  getter list_of_database_read_offsets = [] of Int64
  # The label the next syncs are recorded under.
  property phase = "open"

  @files = {} of String => Grant::SQLiteEngine::MemoryFile

  def open(path : String) : Grant::SQLiteEngine::DatabaseFile
    file = @files[path] ||= Grant::SQLiteEngine::MemoryFile.new
    CountingFile.new(self, SQLiteEngineCountingFileSystem.kind_of(path), file)
  end

  def exists?(path : String) : Bool
    @files.has_key?(path)
  end

  def delete(path : String) : Nil
    @files.delete(path)
  end

  def self.kind_of(path : String) : FileKind
    return FileKind::Journal if path.ends_with?("-journal")
    return FileKind::Wal if path.ends_with?("-wal")
    return FileKind::WalIndex if path.ends_with?("-shm")
    FileKind::Database
  end

  protected def record_writeback(kind : FileKind, offset : Int64, length : Int64, written_size : Int64) : Nil
    @list_of_writeback_requests << WritebackRequest.new(kind, offset, length, written_size)
  end

  protected def record_sync(kind : FileKind, mode : Grant::SQLiteEngine::SyncMode) : Nil
    @list_of_sync_calls << SyncCall.new(kind, mode, @phase)
  end

  # The syncs recorded as "phase file mode" lines.
  def list_of_sync_lines : Array(String)
    @list_of_sync_calls.map(&.to_s)
  end

  # One open file: the bytes live in a `MemoryFile`; each sync is recorded.
  class CountingFile < Grant::SQLiteEngine::DatabaseFile
    def initialize(@file_system : SQLiteEngineCountingFileSystem, @kind : FileKind, @file : Grant::SQLiteEngine::MemoryFile)
    end

    def size : Int64
      @file.size
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      read = @file.read_at(offset, buffer)
      @file_system.list_of_database_read_offsets << offset if @kind.database?
      read
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      @file.write_at(offset, bytes_to_write)
    end

    def start_writeback(offset : Int64, length : Int64) : Nil
      @file_system.record_writeback(@kind, offset, length, @file.size)
    end

    def truncate(size : Int64) : Nil
      @file.truncate(size)
    end

    def lock(level : Grant::SQLiteEngine::LockLevel) : Bool
      @file.lock(level)
    end

    def unlock(level : Grant::SQLiteEngine::LockLevel) : Nil
      @file.unlock(level)
    end

    def lock_level : Grant::SQLiteEngine::LockLevel
      @file.lock_level
    end

    def reserved_elsewhere? : Bool
      @file.reserved_elsewhere?
    end

    def sync : Nil
      sync(Grant::SQLiteEngine::SyncMode::Normal)
    end

    def sync(mode : Grant::SQLiteEngine::SyncMode) : Nil
      @file_system.record_sync(@kind, mode)
    end

    def close : Nil
    end
  end
end
