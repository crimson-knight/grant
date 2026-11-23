module Grant::SQLiteEngine
  # The lock a connection holds on a database file (lockingv3.html §3).
  enum LockLevel
    None
    Shared
    Reserved
    Pending
    Exclusive
  end

  # A database or journal file the writer reads, writes and syncs. The
  # crash simulator implements it in memory to record every write and sync.
  abstract class DatabaseFile < ByteSource
    # Writes *bytes_to_write* at *offset*, growing the file when needed.
    abstract def write_at(offset : Int64, bytes_to_write : Bytes) : Nil

    # Makes every earlier write durable (fsync).
    abstract def sync : Nil

    abstract def truncate(size : Int64) : Nil

    # Moves this connection's lock up to *level*. Returns false, holding the
    # lock it had, when another process holds a conflicting lock.
    abstract def lock(level : LockLevel) : Bool

    # Moves this connection's lock down to *level* (None or Shared).
    abstract def unlock(level : LockLevel) : Nil

    # The lock this connection holds.
    abstract def lock_level : LockLevel

    # True when another process holds the RESERVED lock (pagerHasHotJournal).
    abstract def reserved_elsewhere? : Bool
  end

  # Opens, tests and deletes the files of one database: the database and
  # its rollback journal.
  abstract class FileSystem
    abstract def open(path : String) : DatabaseFile
    abstract def exists?(path : String) : Bool
    abstract def delete(path : String) : Nil
  end

  # The operating system's files, with the POSIX advisory locks C SQLite
  # takes (os_unix.c), so a `sqlite3` process and the engine never write one
  # file at the same time.
  class PosixFileSystem < FileSystem
    def open(path : String) : DatabaseFile
      PosixFile.new(path)
    end

    def exists?(path : String) : Bool
      File.exists?(path)
    end

    def delete(path : String) : Nil
      File.delete?(path)
    end
  end

  # fcntl(2) byte-range locks, bound from the C library Crystal already
  # links. The `flock` layout and command numbers differ between macOS and
  # Linux.
  lib LibFileLock
    {% if flag?(:darwin) %}
      struct Flock
        l_start : Int64
        l_len : Int64
        l_pid : Int32
        l_type : Int16
        l_whence : Int16
      end

      F_GETLK = 7
      F_SETLK = 8
      F_RDLCK = 1
      F_UNLCK = 2
      F_WRLCK = 3
    {% else %}
      struct Flock
        l_type : Int16
        l_whence : Int16
        l_start : Int64
        l_len : Int64
        l_pid : Int32
      end

      F_GETLK = 5
      F_SETLK = 6
      F_RDLCK = 0
      F_WRLCK = 1
      F_UNLCK = 2
    {% end %}

    fun fcntl(fd : Int32, command : Int32, ...) : Int32
  end

  # A file opened read-write (created 0644, masked by the umask, when it
  # does not exist), locked the way os_unix.c locks it: the PENDING byte at
  # 2^30, the RESERVED byte after it and the 510-byte SHARED range after that.
  class PosixFile < DatabaseFile
    PENDING_BYTE = Pager::PENDING_BYTE_OFFSET
    RESERVED_BYTE = PENDING_BYTE + 1
    SHARED_FIRST = PENDING_BYTE + 2
    SHARED_SIZE = 510_i64

    getter lock_level : LockLevel = LockLevel::None

    def initialize(path : String)
      @file = File.open(path, File.exists?(path) ? "r+b" : "w+b")
      @file.read_buffering = false
      @file.sync = true
    end

    def size : Int64
      @file.info.size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      @file.pos = offset
      total = 0
      while total < buffer.size
        count = @file.read(buffer[total..])
        break if count == 0
        total += count
      end
      total
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      @file.pos = offset
      @file.write(bytes_to_write)
    end

    def sync : Nil
      @file.fsync
    end

    def truncate(size : Int64) : Nil
      @file.truncate(size)
    end

    def close : Nil
      @file.close
    end

    def lock(level : LockLevel) : Bool
      return true if level <= @lock_level
      case level
      when .shared?
        return false unless set_lock(LibFileLock::F_RDLCK, PENDING_BYTE, 1)
        acquired = set_lock(LibFileLock::F_RDLCK, SHARED_FIRST, SHARED_SIZE)
        set_lock(LibFileLock::F_UNLCK, PENDING_BYTE, 1)
        return false unless acquired
      when .reserved?
        return false unless set_lock(LibFileLock::F_WRLCK, RESERVED_BYTE, 1)
      else
        # PENDING keeps new readers out while the existing ones finish; it
        # stays held when EXCLUSIVE is not granted yet.
        if @lock_level < LockLevel::Pending
          return false unless set_lock(LibFileLock::F_WRLCK, PENDING_BYTE, 1)
          @lock_level = LockLevel::Pending
        end
        return level.pending? if level.pending?
        return false unless set_lock(LibFileLock::F_WRLCK, SHARED_FIRST, SHARED_SIZE)
      end
      @lock_level = level
      true
    end

    def unlock(level : LockLevel) : Nil
      return if level >= @lock_level
      if level.shared?
        set_lock(LibFileLock::F_RDLCK, SHARED_FIRST, SHARED_SIZE) if @lock_level.exclusive?
        set_lock(LibFileLock::F_UNLCK, PENDING_BYTE, 2)
      else
        set_lock(LibFileLock::F_UNLCK, 0_i64, 0_i64)
      end
      @lock_level = level
    end

    def reserved_elsewhere? : Bool
      return false if @lock_level >= LockLevel::Reserved
      request = LibFileLock::Flock.new
      request.l_type = LibFileLock::F_WRLCK.to_i16
      request.l_whence = IO::Seek::Set.value.to_i16
      request.l_start = RESERVED_BYTE
      request.l_len = 1_i64
      return false if LibFileLock.fcntl(@file.fd, LibFileLock::F_GETLK, pointerof(request)) != 0
      request.l_type != LibFileLock::F_UNLCK
    end

    private def set_lock(type : Int32, start : Int64, length : Int64) : Bool
      request = LibFileLock::Flock.new
      request.l_type = type.to_i16
      request.l_whence = IO::Seek::Set.value.to_i16
      request.l_start = start
      request.l_len = length
      LibFileLock.fcntl(@file.fd, LibFileLock::F_SETLK, pointerof(request)) == 0
    end
  end
end
