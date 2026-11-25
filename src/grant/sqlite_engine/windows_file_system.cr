{% if flag?(:win32) %}
  require "c/fileapi"
  require "c/handleapi"

  module Grant::SQLiteEngine
    # The Win32 calls os_win.c makes on a file handle, bound through the
    # declarations Crystal's own `LibC` already has. `WindowsFile` and
    # `WindowsSharedMemory` share them.
    module WindowsHandle
      # winIoerrCanRetry1: errors an antivirus scanner, the search indexer or
      # another process briefly holding the file cause, which os_win.c waits
      # out instead of failing.
      LIST_OF_RETRYABLE_ERRORS = {
        WinError::ERROR_ACCESS_DENIED, WinError::ERROR_SHARING_VIOLATION,
        WinError::ERROR_LOCK_VIOLATION, WinError::ERROR_DEV_NOT_EXIST,
        WinError::ERROR_NETNAME_DELETED, WinError::ERROR_SEM_TIMEOUT,
        WinError::ERROR_NETWORK_UNREACHABLE,
      }

      # SQLITE_WIN32_IOERR_RETRY and SQLITE_WIN32_IOERR_RETRY_DELAY: ten more
      # tries, pausing 25 ms longer before each one.
      RETRY_LIMIT = 10
      RETRY_DELAY = 25.milliseconds

      # winOpen shares the file for reading and writing with every other
      # handle. Deleting is shared too, so a connection may remove a journal
      # or `-wal` file another connection of this process still has open.
      SHARE_MODE = LibC::DWORD.new(LibC::FILE_SHARE_READ | LibC::FILE_SHARE_WRITE | LibC::FILE_SHARE_DELETE)

      # SetFilePointerEx's FILE_BEGIN.
      FROM_START = LibC::DWORD.new(0)

      # Runs the block until it reports success (true), as winRetryIoerr
      # does: after a retryable error it pauses and tries again, up to
      # `RETRY_LIMIT` times. Returns nil on success, or the error that ended
      # the tries. The block makes the Win32 call last, so its error is
      # still `WinError.value` when the block returns.
      def self.retrying(& : -> Bool) : WinError?
        attempt = 0
        loop do
          return nil if yield
          error = WinError.value
          return error unless attempt < RETRY_LIMIT && LIST_OF_RETRYABLE_ERRORS.includes?(error)
          attempt += 1
          sleep RETRY_DELAY * attempt
        end
      end

      # Opens (creating) *path* for reading and writing (winOpen with
      # SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE).
      def self.open(path : String) : LibC::HANDLE
        wide_path = path.check_no_null_byte.to_utf16
        handle = LibC::INVALID_HANDLE_VALUE
        error = retrying do
          handle = LibC.CreateFileW(wide_path, LibC::DWORD.new!(LibC::GENERIC_READ | LibC::GENERIC_WRITE), SHARE_MODE, nil,
            LibC::DWORD.new(LibC::OPEN_ALWAYS), LibC::DWORD.new(LibC::FILE_ATTRIBUTE_NORMAL), LibC::HANDLE.null)
          handle != LibC::INVALID_HANDLE_VALUE
        end
        raise File::Error.from_os_error("Error opening file", error, file: path) if error
        handle
      end

      def self.close(handle : LibC::HANDLE) : Nil
        LibC.CloseHandle(handle)
      end

      # The OVERLAPPED that addresses byte *offset* of a file opened without
      # FILE_FLAG_OVERLAPPED: ReadFile, WriteFile and LockFileEx take their
      # position from it.
      def self.overlapped_at(offset : Int64) : LibC::OVERLAPPED
        overlapped = LibC::OVERLAPPED.new
        overlapped.union.offset.offset = LibC::DWORD.new!(offset)
        overlapped.union.offset.offsetHigh = LibC::DWORD.new!(offset >> 32)
        overlapped
      end

      # Fills *buffer* from *offset* (winRead). Returns the number of bytes
      # read, which is less than the buffer only at the end of the file.
      def self.read_at(handle : LibC::HANDLE, offset : Int64, buffer : Bytes) : Int32
        total = 0
        while total < buffer.size
          remaining = buffer[total..]
          overlapped = overlapped_at(offset + total)
          count = LibC::DWORD.new(0)
          error = retrying do
            LibC.ReadFile(handle, remaining.to_unsafe, LibC::DWORD.new(remaining.size), pointerof(count), pointerof(overlapped)) != 0
          end
          if error
            break if error.error_handle_eof?
            raise IO::Error.from_os_error("Error reading file", error)
          end
          break if count == 0
          total += count.to_i32
        end
        total
      end

      # Writes all of *bytes* at *offset*, growing the file when needed
      # (winWrite).
      def self.write_at(handle : LibC::HANDLE, offset : Int64, bytes : Bytes) : Nil
        written = 0
        while written < bytes.size
          remaining = bytes[written..]
          overlapped = overlapped_at(offset + written)
          count = LibC::DWORD.new(0)
          error = retrying do
            LibC.WriteFile(handle, remaining.to_unsafe, LibC::DWORD.new(remaining.size), pointerof(count), pointerof(overlapped)) != 0
          end
          raise IO::Error.from_os_error("Error writing file", error) if error
          raise IO::Error.new("Error writing file: nothing written") if count == 0
          written += count.to_i32
        end
      end

      # winSync: FlushFileBuffers writes the file's data and metadata
      # through the drive's cache.
      def self.sync(handle : LibC::HANDLE) : Nil
        raise IO::Error.from_winerror("Error flushing file") if LibC.FlushFileBuffers(handle) == 0
      end

      def self.size(handle : LibC::HANDLE) : Int64
        information = LibC::BY_HANDLE_FILE_INFORMATION.new
        raise IO::Error.from_winerror("Error reading file size") if LibC.GetFileInformationByHandle(handle, pointerof(information)) == 0
        (information.nFileSizeHigh.to_i64 << 32) | information.nFileSizeLow.to_i64
      end

      # Sets the file's size to *size* (winTruncate: move the file pointer,
      # then SetEndOfFile).
      def self.truncate(handle : LibC::HANDLE, size : Int64) : Nil
        if error = truncate_error(handle, size)
          raise IO::Error.from_os_error("Error truncating file", error)
        end
      end

      # Sets the file's size to *size*; returns the error that stopped it, or
      # nil. ERROR_USER_MAPPED_FILE says a view of the file is still mapped.
      def self.truncate_error(handle : LibC::HANDLE, size : Int64) : WinError?
        return nil if LibC.SetFilePointerEx(handle, size, nil, FROM_START) != 0 && LibC.SetEndOfFile(handle) != 0
        WinError.value
      end

      # Takes the byte-range lock *start* to *start* + *length* - 1 without
      # waiting (winLockFile with LOCKFILE_FAIL_IMMEDIATELY). Returns false
      # when another handle holds a conflicting lock.
      def self.lock(handle : LibC::HANDLE, start : Int64, length : Int64, *, exclusive : Bool) : Bool
        flags = LibC::LOCKFILE_FAIL_IMMEDIATELY
        flags |= LibC::LOCKFILE_EXCLUSIVE_LOCK if exclusive
        overlapped = overlapped_at(start)
        LibC.LockFileEx(handle, flags, 0, LibC::DWORD.new!(length), LibC::DWORD.new!(length >> 32), pointerof(overlapped)) != 0
      end

      # Releases the byte-range lock taken by `lock` with the same *start*
      # and *length* (winUnlockFile). A range that is not locked is left
      # alone, as os_win.c ignores ERROR_NOT_LOCKED.
      def self.unlock(handle : LibC::HANDLE, start : Int64, length : Int64) : Nil
        overlapped = overlapped_at(start)
        LibC.UnlockFileEx(handle, 0, LibC::DWORD.new!(length), LibC::DWORD.new!(length >> 32), pointerof(overlapped))
      end

      # Removes *path* (winDelete): a missing file is already gone, and a
      # sharing violation from a scanner or another process holding the file
      # is waited out as `retrying` does.
      def self.delete(path : String) : Nil
        wide_path = path.check_no_null_byte.to_utf16
        error = retrying do
          LibC.DeleteFileW(wide_path) != 0 || WinError.value.error_file_not_found? || WinError.value.error_path_not_found?
        end
        raise File::Error.from_os_error("Error deleting file", error, file: path) if error
      end
    end

    # The operating system's files on Windows, with the LockFileEx locks C
    # SQLite takes there (os_win.c), so a `sqlite3` process and the engine
    # never write one file at the same time.
    class WindowsFileSystem < FileSystem
      def open(path : String) : DatabaseFile
        WindowsFile.new(path)
      end

      def exists?(path : String) : Bool
        File.exists?(path)
      end

      def delete(path : String) : Nil
        WindowsHandle.delete(path)
      end

      def open_shared_memory(path : String) : SharedMemory
        WindowsSharedMemory.new(path)
      end
    end

    # A file opened read-write (created when it does not exist), read and
    # written at explicit offsets and locked the way os_win.c's winLock
    # locks it on Windows NT: LockFileEx on the PENDING byte at 2^30, the
    # RESERVED byte after it, and the 510-byte SHARED range after that, held
    # shared by every reader and exclusively by the writer.
    #
    # Unlike POSIX locks, Windows locks belong to the handle, so each
    # connection opens its own handle and holds its own locks, as each
    # winFile does. The process lock table still orders the connections of
    # this process the way it does on POSIX systems.
    class WindowsFile < DatabaseFile
      PENDING_BYTE  = Pager::PENDING_BYTE_OFFSET
      RESERVED_BYTE = PENDING_BYTE + 1
      SHARED_FIRST  = PENDING_BYTE + 2
      SHARED_SIZE   = 510_i64

      # winLock tries the PENDING byte three times, 1 ms apart, because an
      # antivirus scanner or the indexer may hold it for a moment.
      PENDING_ATTEMPTS = 3

      getter lock_level : LockLevel = LockLevel::None

      # The locks this handle holds on the operating system. They can run
      # ahead of `lock_level`: a refused EXCLUSIVE from RESERVED keeps the
      # PENDING byte, as winLock does, so new readers wait for the writer.
      @holds_read_lock = false
      @holds_reserved_lock = false
      @holds_pending_lock = false
      @holds_exclusive_lock = false
      @closed = false

      @handle : LibC::HANDLE
      @shared_locks : ProcessLockTable::FileLocks

      def initialize(path : String)
        @handle = WindowsHandle.open(path)
        @shared_locks = WindowsFile.lock_table_for(path, @handle)
      end

      # The process lock table entry of *path*; closes *handle* when the path
      # cannot be resolved.
      protected def self.lock_table_for(path : String, handle : LibC::HANDLE) : ProcessLockTable::FileLocks
        ProcessLockTable.for(File.realpath(path))
      rescue error
        WindowsHandle.close(handle)
        raise error
      end

      def size : Int64
        WindowsHandle.size(@handle)
      end

      def read_at(offset : Int64, buffer : Bytes) : Int32
        WindowsHandle.read_at(@handle, offset, buffer)
      end

      def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
        WindowsHandle.write_at(@handle, offset, bytes_to_write)
      end

      # winSync makes no difference between a normal and a full sync:
      # FlushFileBuffers already empties the drive's write cache.
      def sync : Nil
        WindowsHandle.sync(@handle)
      end

      def truncate(size : Int64) : Nil
        WindowsHandle.truncate(@handle, size)
      end

      # Releases this connection's locks and closes its handle.
      def close : Nil
        return if @closed
        @closed = true
        unlock(LockLevel::None)
        release_locks(LockLevel::None)
        @shared_locks.forget(self)
        WindowsHandle.close(@handle)
      end

      def lock(level : LockLevel) : Bool
        return true if level <= @lock_level
        @shared_locks.synchronize do
          return false if @shared_locks.refuses?(self, level)
          return false unless take_locks(level)
          @lock_level = level
          @shared_locks.set(self, level)
          true
        end
      end

      def unlock(level : LockLevel) : Nil
        return if level >= @lock_level
        @shared_locks.synchronize do
          release_locks(level)
          @lock_level = level
          @shared_locks.set(self, level)
        end
      end

      # winCheckReservedLock: the RESERVED byte is held elsewhere when a
      # shared lock on it is refused.
      def reserved_elsewhere? : Bool
        return false if @lock_level >= LockLevel::Reserved
        return true if @shared_locks.synchronize { @shared_locks.highest_other(self) >= LockLevel::Reserved }
        return true unless WindowsHandle.lock(@handle, RESERVED_BYTE, 1, exclusive: false)
        WindowsHandle.unlock(@handle, RESERVED_BYTE, 1)
        false
      end

      # winLock: moves this handle's locks up from `lock_level` to *level*.
      # Returns false when another handle holds a conflicting lock.
      private def take_locks(level : LockLevel) : Bool
        unless @holds_read_lock || @holds_exclusive_lock
          return false unless take_read_lock_through_pending
          return true if level.shared?
        end
        if level >= LockLevel::Reserved && !@holds_reserved_lock
          @holds_reserved_lock = WindowsHandle.lock(@handle, RESERVED_BYTE, 1, exclusive: true)
          unless @holds_reserved_lock
            release_locks(@lock_level)
            return false
          end
          return true if level.reserved?
        end
        unless @holds_pending_lock
          @holds_pending_lock = take_pending_lock(exclusive: true)
          unless @holds_pending_lock
            release_locks(@lock_level) if @lock_level < LockLevel::Reserved
            return false
          end
        end
        return true if level.pending?
        release_read_lock
        @holds_exclusive_lock = WindowsHandle.lock(@handle, SHARED_FIRST, SHARED_SIZE, exclusive: true)
        return true if @holds_exclusive_lock
        # Readers are still there: take the read lock back and, from SHARED,
        # drop the RESERVED and PENDING bytes this call took.
        @holds_read_lock = WindowsHandle.lock(@handle, SHARED_FIRST, SHARED_SIZE, exclusive: false)
        release_locks(@lock_level) if @lock_level < LockLevel::Reserved
        false
      end

      # winLock's path to SHARED: a shared lock on the PENDING byte keeps
      # out a writer that is waiting for readers to finish; it is released
      # once the read lock is held.
      private def take_read_lock_through_pending : Bool
        return false unless take_pending_lock(exclusive: false)
        @holds_read_lock = WindowsHandle.lock(@handle, SHARED_FIRST, SHARED_SIZE, exclusive: false)
        WindowsHandle.unlock(@handle, PENDING_BYTE, 1)
        @holds_read_lock
      end

      private def take_pending_lock(*, exclusive : Bool) : Bool
        PENDING_ATTEMPTS.times do |attempt|
          return true if WindowsHandle.lock(@handle, PENDING_BYTE, 1, exclusive: exclusive)
          sleep 1.millisecond if attempt < PENDING_ATTEMPTS - 1
        end
        false
      end

      # winGetReadLock's opposite (winUnlockReadLock).
      private def release_read_lock : Nil
        return unless @holds_read_lock
        WindowsHandle.unlock(@handle, SHARED_FIRST, SHARED_SIZE)
        @holds_read_lock = false
      end

      # winUnlock: moves this handle's locks down to *level* (None, Shared
      # or Reserved).
      private def release_locks(level : LockLevel) : Nil
        if @holds_exclusive_lock
          WindowsHandle.unlock(@handle, SHARED_FIRST, SHARED_SIZE)
          @holds_exclusive_lock = false
        end
        if level >= LockLevel::Shared && !@holds_read_lock
          @holds_read_lock = WindowsHandle.lock(@handle, SHARED_FIRST, SHARED_SIZE, exclusive: false)
        end
        if level < LockLevel::Reserved && @holds_reserved_lock
          WindowsHandle.unlock(@handle, RESERVED_BYTE, 1)
          @holds_reserved_lock = false
        end
        release_read_lock if level.none?
        if level < LockLevel::Pending && @holds_pending_lock
          WindowsHandle.unlock(@handle, PENDING_BYTE, 1)
          @holds_pending_lock = false
        end
      end
    end
  end
{% end %}
