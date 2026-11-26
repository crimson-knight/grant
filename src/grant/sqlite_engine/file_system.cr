module Grant::SQLiteEngine
  # The lock a connection holds on a database file (lockingv3.html §3).
  enum LockLevel
    None
    Shared
    Reserved
    Pending
    Exclusive
  end

  # How hard a sync pushes a file to the disk (SQLITE_SYNC_NORMAL and
  # SQLITE_SYNC_FULL of os_unix.c): `Normal` is fdatasync on Linux and fsync
  # elsewhere; `Full` is macOS's `fcntl(F_FULLFSYNC)`, which also empties the
  # drive's write cache, and is the `Normal` sync on the other systems.
  enum SyncMode
    Normal
    Full
  end

  # A database or journal file the writer reads, writes and syncs. The
  # crash simulator implements it in memory to record every write and sync.
  abstract class DatabaseFile < ByteSource
    # Writes *bytes_to_write* at *offset*, growing the file when needed.
    abstract def write_at(offset : Int64, bytes_to_write : Bytes) : Nil

    # Makes every earlier write durable (fsync).
    abstract def sync : Nil

    # Makes every earlier write durable the way *mode* asks. A file that
    # has only one kind of sync uses it for both modes.
    def sync(mode : SyncMode) : Nil
      sync
    end

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
    # The operating system's own files with the locks C SQLite takes there:
    # `WindowsFileSystem` (os_win.c) on Windows, `PosixFileSystem`
    # (os_unix.c) everywhere else.
    def self.native : FileSystem
      {% if flag?(:win32) %}
        WindowsFileSystem.new
      {% else %}
        PosixFileSystem.new
      {% end %}
    end

    abstract def open(path : String) : DatabaseFile

    # Opens the rollback journal *path* for a commit to write, empty: created
    # when it does not exist, cut to nothing when it does.
    def create_journal(path : String) : DatabaseFile
      journal = open(path)
      journal.truncate(0)
      journal
    end

    abstract def exists?(path : String) : Bool
    abstract def delete(path : String) : Nil

    # Opens (creating) the wal-index file *path* for one connection. File
    # systems the engine provides keep it as an ordinary file of theirs.
    def open_shared_memory(path : String) : SharedMemory
      FileSharedMemory.new(open(path))
    end
  end

  # The operating system's files, with the POSIX advisory locks C SQLite
  # takes (os_unix.c), so a `sqlite3` process and the engine never write one
  # file at the same time. Windows uses `WindowsFileSystem` instead
  # (`FileSystem.native` picks the one for the platform).
  class PosixFileSystem < FileSystem
    def open(path : String) : DatabaseFile
      {% if flag?(:win32) %}
        raise UnsupportedPlatform.new("PosixFileSystem", "Windows", "WindowsFileSystem")
      {% else %}
        PosixFile.new(path)
      {% end %}
    end

    # C's unixOpen of a journal: one open(2) that creates the file or, here,
    # cuts a stale one to nothing (`O_TRUNC`), with no lock and no other call.
    def create_journal(path : String) : DatabaseFile
      {% if flag?(:win32) %}
        raise UnsupportedPlatform.new("PosixFileSystem", "Windows", "WindowsFileSystem")
      {% else %}
        PosixJournalFile.new(path)
      {% end %}
    end

    def exists?(path : String) : Bool
      File.exists?(path)
    end

    def delete(path : String) : Nil
      File.delete?(path)
    end

    def open_shared_memory(path : String) : SharedMemory
      {% if flag?(:win32) %}
        raise UnsupportedPlatform.new("PosixFileSystem", "Windows", "WindowsFileSystem")
      {% else %}
        MappedSharedMemory.new(path)
      {% end %}
    end
  end

  {% unless flag?(:win32) %}
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

    {% if flag?(:darwin) %}
      F_FULLFSYNC = 51
    {% end %}

    fun fcntl(fd : Int32, command : Int32, ...) : Int32
  end

  # pwrite(2), which the standard library's LibC leaves out (it binds pread).
  lib LibPositionedWrite
    fun pwrite(fd : Int32, buffer : Void*, count : LibC::SizeT, offset : LibC::OffT) : LibC::SSizeT
  end

  # Reads and writes at an offset of a descriptor with pread(2) and
  # pwrite(2), as os_unix.c's seekAndRead and seekAndWrite do: one call per
  # transfer, with no lseek(2) first.
  module PositionedIO
    # Reads into *buffer* from *offset* until it is full or the file ends;
    # returns the bytes read.
    def self.read_at(descriptor : Int32, offset : Int64, buffer : Bytes, path : String) : Int32
      total = 0
      while total < buffer.size
        count = LibC.pread(descriptor, (buffer + total).to_unsafe.as(Void*), buffer.size - total, offset + total)
        if count < 0
          next if Errno.value == Errno::EINTR
          raise IO::Error.from_errno("Error reading #{path}")
        end
        break if count == 0
        total += count
      end
      total
    end

    # Writes all of *bytes_to_write* at *offset*.
    def self.write_at(descriptor : Int32, offset : Int64, bytes_to_write : Bytes, path : String) : Nil
      written = 0
      while written < bytes_to_write.size
        count = LibPositionedWrite.pwrite(descriptor, (bytes_to_write + written).to_unsafe.as(Void*),
          bytes_to_write.size - written, offset + written)
        if count < 0
          next if Errno.value == Errno::EINTR
          raise IO::Error.from_errno("Error writing #{path}")
        end
        written += count
      end
    end

    # unixSync on *descriptor*: `fcntl(F_FULLFSYNC)` for a `Full` sync on
    # macOS, falling back when the file system refuses it; fdatasync on
    # Linux; fsync elsewhere.
    def self.sync(descriptor : Int32, mode : SyncMode, path : String) : Nil
      return if mode.full? && PosixFile.full_fsync?(descriptor)
      result = PosixFile.sync_flushes_metadata? ? LibC.fsync(descriptor) : LibC.fdatasync(descriptor)
      raise IO::Error.from_errno("Error syncing #{path}") if result != 0
    end
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
      PositionedIO.read_at(@file.fd, offset, buffer, @file.path)
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      PositionedIO.write_at(@file.fd, offset, bytes_to_write, @file.path)
    end

    def sync : Nil
      sync(SyncMode::Normal)
    end

    # unixSync and full_fsync: a `Full` sync on macOS asks the drive itself
    # to write its cache (F_FULLFSYNC), and falls back to fsync on a file
    # system that refuses the request. Every other sync is fdatasync on
    # Linux, as C SQLite's build there does (HAVE_FDATASYNC): it flushes the
    # data and the metadata needed to read it back (the file size), and
    # leaves out the timestamps. Elsewhere it is fsync.
    def sync(mode : SyncMode) : Nil
      PositionedIO.sync(@file.fd, mode, @file.path)
    end

    # True where a sync is fsync (every metadata field); false on Linux,
    # where it is fdatasync.
    def self.sync_flushes_metadata? : Bool
      {% if flag?(:linux) %}
        false
      {% else %}
        true
      {% end %}
    end

    # Runs `fcntl(F_FULLFSYNC)` on *descriptor* and tells whether it
    # succeeded; false on a system without it.
    def self.full_fsync?(descriptor : Int32) : Bool
      {% if flag?(:darwin) %}
        LibFileLock.fcntl(descriptor, LibFileLock::F_FULLFSYNC, 0) == 0
      {% else %}
        false
      {% end %}
    end

    def truncate(size : Int64) : Nil
      @file.truncate(size)
    end

    # Closing a descriptor drops every POSIX lock the process holds on the
    # file, so while other connections of this process still have it open
    # the descriptor is kept (as os_unix.c's unused list does) and closed
    # with the last one.
    def close : Nil
      unlock(LockLevel::None)
      @shared_locks.release(self, @file)
    end

    def lock(level : LockLevel) : Bool
      return true if level <= @lock_level
      @shared_locks.synchronize do
          return false if @shared_locks.refuses?(self, level)
        held = @shared_locks.process_level
        if level > held
          unless process_lock(level, held)
            # A refused EXCLUSIVE from SHARED keeps no RESERVED or PENDING
            # byte (C's pager unlocks after a busy hot-journal or close).
            process_unlock(held) if held == LockLevel::Shared && level.exclusive?
            return false
          end
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
        # The PENDING byte and, below RESERVED, the RESERVED byte after it
        # in one call, as posixUnlock does.
        set_lock(LibFileLock::F_UNLCK, PENDING_BYTE, level < LockLevel::Reserved ? 2_i64 : 1_i64)
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

  # A rollback journal a commit writes: one open(2) creating it or cutting a
  # stale one to nothing, positioned reads and writes, and no locks (C locks
  # only the database file). Its first sync also syncs the folder that holds
  # it, so the new journal's name is on the disk before the commit counts on
  # it, as os_unix.c does for a journal it creates (UNIXFILE_DIRSYNC).
  class PosixJournalFile < DatabaseFile
    @directory_sync_due = true

    def initialize(@path : String)
      @descriptor = LibC.open(@path, LibC::O_RDWR | LibC::O_CREAT | LibC::O_TRUNC | LibC::O_CLOEXEC, 0o644)
      raise IO::Error.from_errno("Error opening #{@path}") if @descriptor < 0
    end

    def size : Int64
      raise IO::Error.from_errno("Error reading the size of #{@path}") if LibC.fstat(@descriptor, out status) != 0
      status.st_size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      PositionedIO.read_at(@descriptor, offset, buffer, @path)
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      PositionedIO.write_at(@descriptor, offset, bytes_to_write, @path)
    end

    def sync : Nil
      sync(SyncMode::Normal)
    end

    # unixSync: the file, then, the first time, its folder, whose sync
    # failing is ignored as C ignores it. A folder's sync is a plain one
    # (full_fsync of the directory asks no F_FULLFSYNC).
    def sync(mode : SyncMode) : Nil
      PositionedIO.sync(@descriptor, mode, @path)
      return unless @directory_sync_due
      @directory_sync_due = false
      directory = LibC.open(File.dirname(@path), LibC::O_RDONLY | LibC::O_CLOEXEC)
      return if directory < 0
      PosixFile.sync_flushes_metadata? ? LibC.fsync(directory) : LibC.fdatasync(directory)
      LibC.close(directory)
    end

    def truncate(size : Int64) : Nil
      raise IO::Error.from_errno("Error truncating #{@path}") if LibC.ftruncate(@descriptor, size) != 0
    end

    def close : Nil
      return if @descriptor < 0
      LibC.close(@descriptor)
      @descriptor = -1
    end

    # The journal takes no lock; the database file's lock covers it.
    def lock(level : LockLevel) : Bool
      true
    end

    def unlock(level : LockLevel) : Nil
    end

    def lock_level : LockLevel
      LockLevel::None
    end

    def reserved_elsewhere? : Bool
      false
    end
  end
  {% end %}

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

      @list_of_unused_files = [] of File

      # Forgets *file*'s lock and closes *descriptor*, or keeps it open
      # while another connection of the process still uses the file.
      def release(file : DatabaseFile, descriptor : File) : Nil
        synchronize do
          @levels.delete(file.object_id)
          if @levels.empty?
            @list_of_unused_files.each(&.close)
            @list_of_unused_files.clear
            descriptor.close
          else
            @list_of_unused_files << descriptor
          end
        end
      end

      # Forgets *file*'s lock when it closes. On Windows each connection has
      # its own handle, whose locks go with it, so there is no descriptor to
      # keep open.
      def forget(file : DatabaseFile) : Nil
        synchronize { @levels.delete(file.object_id) }
      end

      # True when another connection of this process holds a lock that
      # keeps *file* from moving up to *level* (unixLock's checks against
      # the other connections of one unixInodeInfo).
      def refuses?(file : DatabaseFile, level : LockLevel) : Bool
        others = highest_other(file)
        case level
        when .shared?
          others >= LockLevel::Pending
        when .reserved?
          others >= LockLevel::Reserved
        when .pending?
          others >= LockLevel::Pending
        else
          others >= LockLevel::Shared || any_other_shared?(file)
        end
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
