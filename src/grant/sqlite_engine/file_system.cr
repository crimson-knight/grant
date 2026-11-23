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
    PENDING_BYTE  = Pager::PENDING_BYTE_OFFSET
    RESERVED_BYTE = PENDING_BYTE + 1
    SHARED_FIRST  = PENDING_BYTE + 2
    SHARED_SIZE   = 510_i64

    getter lock_level : LockLevel = LockLevel::None

    # Connections of this process that opened the same file share one set
    # of POSIX locks (fcntl locks belong to the process, so two descriptors
    # never block each other); the table orders them as C's unixInodeInfo
    # does.
    @shared_locks : ProcessLockTable::FileLocks

    def initialize(path : String)
      @file = File.open(path, File.exists?(path) ? "r+b" : "w+b")
      @file.read_buffering = false
      @file.sync = true
      @shared_locks = ProcessLockTable.for(File.realpath(path))
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
      unlock(LockLevel::None)
      @shared_locks.release(self)
      @file.close
    end

    def lock(level : LockLevel) : Bool
      return true if level <= @lock_level
      @shared_locks.synchronize do
        others = @shared_locks.highest_other(self)
        case level
        when .shared?
          return false if others >= LockLevel::Pending
        when .reserved?
          return false if others >= LockLevel::Reserved
        when .pending?
          return false if others >= LockLevel::Pending
        else
          return false if others >= LockLevel::Shared || @shared_locks.any_other_shared?(self)
        end
        held = @shared_locks.process_level
        if level > held
          return false unless process_lock(level, held)
        end
        @lock_level = level
        @shared_locks.set(self, level)
        true
      end
    end

    def unlock(level : LockLevel) : Nil
      return if level >= @lock_level
      @shared_locks.synchronize do
        before = @shared_locks.process_level
        @lock_level = level
        @shared_locks.set(self, level)
        after = @shared_locks.process_level
        process_unlock(after) if after < before
      end
    end

    # Moves the process's POSIX locks from *held* up to *level*.
    private def process_lock(level : LockLevel, held : LockLevel) : Bool
      if held < LockLevel::Shared
        return false unless set_lock(LibFileLock::F_RDLCK, PENDING_BYTE, 1)
        acquired = set_lock(LibFileLock::F_RDLCK, SHARED_FIRST, SHARED_SIZE)
        set_lock(LibFileLock::F_UNLCK, PENDING_BYTE, 1)
        return false unless acquired
        return true if level.shared?
      end
      if level >= LockLevel::Reserved && held < LockLevel::Reserved
        unless set_lock(LibFileLock::F_WRLCK, RESERVED_BYTE, 1)
          process_unlock(held)
          return false
        end
        return true if level.reserved?
      end
      if held < LockLevel::Pending
        unless set_lock(LibFileLock::F_WRLCK, PENDING_BYTE, 1)
          return false
        end
      end
      return true if level.pending?
      set_lock(LibFileLock::F_WRLCK, SHARED_FIRST, SHARED_SIZE)
    end

    # Moves the process's POSIX locks down to *level* (None, Shared or
    # Reserved).
    private def process_unlock(level : LockLevel) : Nil
      if level >= LockLevel::Shared
        set_lock(LibFileLock::F_RDLCK, SHARED_FIRST, SHARED_SIZE)
        set_lock(LibFileLock::F_UNLCK, PENDING_BYTE, 1)
        set_lock(LibFileLock::F_UNLCK, RESERVED_BYTE, 1) if level < LockLevel::Reserved
      else
        set_lock(LibFileLock::F_UNLCK, 0_i64, 0_i64)
      end
    end

    def reserved_elsewhere? : Bool
      return false if @lock_level >= LockLevel::Reserved
      return true if @shared_locks.synchronize { @shared_locks.highest_other(self) >= LockLevel::Reserved }
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

  # The lock each connection of this process holds on each database file
  # (by real path), so that connections of one process exclude each other
  # as connections of different processes do.
  module ProcessLockTable
    class FileLocks
      @levels = {} of UInt64 => LockLevel
      @mutex = Mutex.new(:reentrant)

      def synchronize(& : -> T) : T forall T
        @mutex.synchronize { yield }
      end

      def set(file : DatabaseFile, level : LockLevel) : Nil
        @levels[file.object_id] = level
      end

      def release(file : DatabaseFile) : Nil
        synchronize { @levels.delete(file.object_id) }
      end

      def highest_other(file : DatabaseFile) : LockLevel
        highest = LockLevel::None
        @levels.each { |owner, level| highest = level if owner != file.object_id && level > highest }
        highest
      end

      def any_other_shared?(file : DatabaseFile) : Bool
        @levels.any? { |owner, level| owner != file.object_id && level >= LockLevel::Shared }
      end

      def process_level : LockLevel
        @levels.values.max? || LockLevel::None
      end
    end

    @@table = {} of String => FileLocks
    @@mutex = Mutex.new

    def self.for(path : String) : FileLocks
      @@mutex.synchronize { @@table[path] ||= FileLocks.new }
    end
  end
end
