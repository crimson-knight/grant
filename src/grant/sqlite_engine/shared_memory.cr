module Grant::SQLiteEngine
  # One connection's handle on a database's wal-index file (`-shm`), as
  # os_unix.c's unixShm: the 32 KiB regions every connection reads and
  # writes, and the eight lock slots of walformat.html §2.3.1 (WRITE, CKPT,
  # RECOVER and READ0 to READ4), taken shared or exclusive.
  #
  # Values are stored in the host's byte order, as C SQLite stores them.
  abstract class SharedMemory
    # walformat.html §2.2: each wal-index region is 32 KiB.
    REGION_SIZE = 32_768

    # The eight lock slots (SQLITE_SHM_NLOCK).
    SLOT_COUNT = 8

    # os_unix.c: the lock slots are the bytes 120 to 127 of the file, and
    # byte 128 is the "dead man switch" every open connection holds shared.
    LOCK_BASE      = 120_i64
    DEAD_MAN_BYTE  = 128_i64
    TRUNCATED_SIZE =   3_i64

    # Makes region *index* readable, extending the file when *grow* is
    # set. Returns false when the region is past the end of the file and
    # *grow* is not set.
    abstract def map_region(index : Int32, grow : Bool) : Bool

    # The number of regions mapped so far.
    abstract def mapped_region_count : Int32

    abstract def read_u32(offset : Int32) : UInt32
    abstract def write_u32(offset : Int32, value : UInt32) : Nil
    abstract def read_u16(offset : Int32) : UInt16
    abstract def write_u16(offset : Int32, value : UInt16) : Nil

    # Copies *count* bytes at *offset* into a new buffer.
    def read_bytes(offset : Int32, count : Int32) : Bytes
      bytes = Bytes.new(count)
      read_into(offset, bytes)
      bytes
    end

    # Copies the bytes at *offset* into all of *buffer*.
    abstract def read_into(offset : Int32, buffer : Bytes) : Nil
    abstract def write_bytes(offset : Int32, bytes : Bytes) : Nil

    # Sets *count* bytes from *offset* to zero.
    abstract def zero(offset : Int32, count : Int32) : Nil

    # A memory barrier between two groups of reads or writes (walShmBarrier).
    def barrier : Nil
      Atomic::Ops.fence(:sequentially_consistent, false)
    end

    # Takes slot *slot* shared. Returns false when another connection holds
    # it exclusively.
    abstract def lock_shared(slot : Int32) : Bool

    # Takes slots *slot* to *slot* + *count* - 1 exclusively. Returns false,
    # holding none of them, when another connection holds any of them.
    abstract def lock_exclusive(slot : Int32, count : Int32 = 1) : Bool

    # Releases this connection's locks on slots *slot* to *slot* + *count* - 1.
    abstract def unlock(slot : Int32, count : Int32 = 1) : Nil

    # Releases every lock and the file. With *delete*, the file is removed
    # when this was the last connection of the process to use it.
    abstract def close(delete : Bool) : Nil
  end

  {% unless flag?(:win32) %}
    # The wal-index of a database on disk, shared with every other connection
    # through `mmap(2)` (MAP_SHARED), with C SQLite's fcntl(2) locks on the
    # lock slots. Connections of one process share one mapping and one
    # descriptor, and the lock table orders them as unixShmNode does, because
    # POSIX locks belong to the process.
    class MappedSharedMemory < SharedMemory
      # The mapping, descriptor and lock counts every connection of this
      # process shares for one `-shm` file (unixShmNode).
      class Node
        getter file : File
        getter list_of_regions = [] of Pointer(UInt8)
        # Per slot: the number of connections of this process holding it
        # shared, or -1 when one holds it exclusively.
        getter slot_counts = Array(Int32).new(SharedMemory::SLOT_COUNT, 0)
        getter mutex = Mutex.new(:reentrant)
        property reference_count = 0

        def initialize(@path : String, @file : File)
        end

        def fd : Int32
          @file.fd
        end

        def unmap : Nil
          @list_of_regions.each { |region| LibC.munmap(region.as(Void*), SharedMemory::REGION_SIZE) }
          @list_of_regions.clear
        end
      end

      @@nodes = {} of String => Node
      @@nodes_mutex = Mutex.new

      @node : Node
      @shared_mask = 0
      @exclusive_mask = 0
      @closed = false

      # Opens (creating) *path* and takes the dead man switch: the first
      # connection of any process truncates the file, so a wal-index left by
      # a crash is rebuilt. Raises `Busy` while another process holds the
      # switch exclusively (it is truncating the file).
      def initialize(path : String)
        @node = @@nodes_mutex.synchronize do
          File.touch(path) unless File.exists?(path)
          key = File.realpath(path)
          node = @@nodes[key]?
          unless node
            file = File.open(key, "r+b")
            file.read_buffering = false
            file.sync = true
            node = Node.new(key, file)
            begin
              take_dead_man_switch(node)
            rescue error
              file.close
              raise error
            end
            @@nodes[key] = node
          end
          node.reference_count += 1
          node
        end
      end

      # unixLockSharedMemory.
      private def take_dead_man_switch(node : Node) : Nil
        holder = MappedSharedMemory.lock_holder(node.fd, DEAD_MAN_BYTE)
        if holder == LibFileLock::F_UNLCK
          if MappedSharedMemory.set_lock(node.fd, LibFileLock::F_WRLCK, DEAD_MAN_BYTE, 1)
            if LibC.ftruncate(node.fd, TRUNCATED_SIZE) != 0
              raise Error.new("could not truncate the wal-index file")
            end
          end
        elsif holder == LibFileLock::F_WRLCK
          raise Busy.new
        end
        raise Busy.new unless MappedSharedMemory.set_lock(node.fd, LibFileLock::F_RDLCK, DEAD_MAN_BYTE, 1)
      end

      def map_region(index : Int32, grow : Bool) : Bool
        node = @node
        node.mutex.synchronize do
          return true if index < node.list_of_regions.size
          needed = (index.to_i64 + 1) * REGION_SIZE
          if node.file.info.size < needed
            return false unless grow
            raise Error.new("could not extend the wal-index file") if LibC.ftruncate(node.fd, needed) != 0
          end
          while node.list_of_regions.size <= index
            offset = node.list_of_regions.size.to_i64 * REGION_SIZE
            address = LibC.mmap(Pointer(Void).null, REGION_SIZE, LibC::PROT_READ | LibC::PROT_WRITE, LibC::MAP_SHARED, node.fd, offset)
            raise Error.new("could not map the wal-index file") if address == LibC::MAP_FAILED
            node.list_of_regions << address.as(UInt8*)
          end
          true
        end
      end

      def mapped_region_count : Int32
        @node.list_of_regions.size
      end

      private def address(offset : Int32) : UInt8*
        @node.list_of_regions.unsafe_fetch(offset // REGION_SIZE) + (offset % REGION_SIZE)
      end

      def read_u32(offset : Int32) : UInt32
        address(offset).as(UInt32*).value
      end

      def write_u32(offset : Int32, value : UInt32) : Nil
        address(offset).as(UInt32*).value = value
      end

      def read_u16(offset : Int32) : UInt16
        address(offset).as(UInt16*).value
      end

      def write_u16(offset : Int32, value : UInt16) : Nil
        address(offset).as(UInt16*).value = value
      end

      def read_into(offset : Int32, buffer : Bytes) : Nil
        buffer.to_unsafe.copy_from(address(offset), buffer.size)
      end

      def write_bytes(offset : Int32, bytes : Bytes) : Nil
        address(offset).copy_from(bytes.to_unsafe, bytes.size)
      end

      def zero(offset : Int32, count : Int32) : Nil
        Intrinsics.memset(address(offset).as(Void*), 0_u8, count, false)
      end

      # unixShmLock, shared branch.
      def lock_shared(slot : Int32) : Bool
        mask = 1 << slot
        return true if @shared_mask & mask != 0
        node = @node
        node.mutex.synchronize do
          counts = node.slot_counts
          return false if counts[slot] < 0
          if counts[slot] == 0
            return false unless MappedSharedMemory.set_lock(node.fd, LibFileLock::F_RDLCK, LOCK_BASE + slot, 1)
          end
          counts[slot] += 1
          @shared_mask |= mask
          true
        end
      end

      # unixShmLock, exclusive branch.
      def lock_exclusive(slot : Int32, count : Int32 = 1) : Bool
        node = @node
        node.mutex.synchronize do
          counts = node.slot_counts
          slot.upto(slot + count - 1) do |index|
            return false if @exclusive_mask & (1 << index) == 0 && counts[index] != 0
          end
          return false unless MappedSharedMemory.set_lock(node.fd, LibFileLock::F_WRLCK, LOCK_BASE + slot, count)
          slot.upto(slot + count - 1) do |index|
            counts[index] = -1
            @exclusive_mask |= 1 << index
          end
          true
        end
      end

      # unixShmLock, unlock branch: the process lock goes only when no other
      # connection of the process still holds the slot shared.
      def unlock(slot : Int32, count : Int32 = 1) : Nil
        mask = ((1 << (slot + count)) - (1 << slot))
        return if (@shared_mask | @exclusive_mask) & mask == 0
        node = @node
        node.mutex.synchronize do
          counts = node.slot_counts
          release = true
          slot.upto(slot + count - 1) do |index|
            release = false if counts[index] > (@shared_mask & (1 << index) != 0 ? 1 : 0)
          end
          if release
            MappedSharedMemory.set_lock(node.fd, LibFileLock::F_UNLCK, LOCK_BASE + slot, count)
            slot.upto(slot + count - 1) { |index| counts[index] = 0 }
          else
            counts[slot] -= 1
          end
          @shared_mask &= ~mask
          @exclusive_mask &= ~mask
        end
      end

      # unixShmUnmap: the last connection of the process unmaps the file and
      # closes its descriptor (which drops the dead man switch), removing the
      # file first when *delete* is set.
      def close(delete : Bool) : Nil
        return if @closed
        @closed = true
        unlock(0, SLOT_COUNT)
        @@nodes_mutex.synchronize do
          node = @node
          node.reference_count -= 1
          if node.reference_count == 0
            File.delete?(path_of(node)) if delete
            node.unmap
            node.file.close
            @@nodes.delete(path_of(node))
          end
        end
      end

      private def path_of(node : Node) : String
        node.file.path
      end

      protected def self.set_lock(fd : Int32, type : Int32, start : Int64, length : Int64) : Bool
        request = LibFileLock::Flock.new
        request.l_type = type.to_i16
        request.l_whence = IO::Seek::Set.value.to_i16
        request.l_start = start
        request.l_len = length
        LibFileLock.fcntl(fd, LibFileLock::F_SETLK, pointerof(request)) == 0
      end

      # The strongest lock another process holds on *start* (F_GETLK).
      protected def self.lock_holder(fd : Int32, start : Int64) : Int32
        request = LibFileLock::Flock.new
        request.l_type = LibFileLock::F_WRLCK.to_i16
        request.l_whence = IO::Seek::Set.value.to_i16
        request.l_start = start
        request.l_len = 1_i64
        raise Error.new("could not test the wal-index lock") if LibFileLock.fcntl(fd, LibFileLock::F_GETLK, pointerof(request)) != 0
        request.l_type.to_i32
      end
    end
  {% end %}

  # A wal-index kept in a `DatabaseFile` of a file system the engine
  # provides itself (the in-memory file system, the crash simulator), read
  # and written through `read_at` and `write_at` so every write is seen by
  # the file system. Only this process uses it, so every lock is granted;
  # *survivor* says another (simulated) process still holds the dead man
  # switch, so the file is not truncated when it opens.
  class FileSharedMemory < SharedMemory
    @regions = 0

    def initialize(@file : DatabaseFile, survivor : Bool = false)
      @file.truncate(TRUNCATED_SIZE) unless survivor
    end

    def map_region(index : Int32, grow : Bool) : Bool
      needed = (index.to_i64 + 1) * REGION_SIZE
      if @file.size < needed
        return false unless grow
        @file.write_at(needed - 1, Bytes.new(1))
      end
      @regions = index + 1 if index >= @regions
      true
    end

    def mapped_region_count : Int32
      @regions
    end

    def read_u32(offset : Int32) : UInt32
      IO::ByteFormat::SystemEndian.decode(UInt32, read_bytes(offset, 4))
    end

    def write_u32(offset : Int32, value : UInt32) : Nil
      bytes = Bytes.new(4)
      IO::ByteFormat::SystemEndian.encode(value, bytes)
      write_bytes(offset, bytes)
    end

    def read_u16(offset : Int32) : UInt16
      IO::ByteFormat::SystemEndian.decode(UInt16, read_bytes(offset, 2))
    end

    def write_u16(offset : Int32, value : UInt16) : Nil
      bytes = Bytes.new(2)
      IO::ByteFormat::SystemEndian.encode(value, bytes)
      write_bytes(offset, bytes)
    end

    def read_into(offset : Int32, buffer : Bytes) : Nil
      @file.read_at(offset.to_i64, buffer)
    end

    def write_bytes(offset : Int32, bytes : Bytes) : Nil
      @file.write_at(offset.to_i64, bytes)
    end

    def zero(offset : Int32, count : Int32) : Nil
      @file.write_at(offset.to_i64, Bytes.new(count))
    end

    def lock_shared(slot : Int32) : Bool
      true
    end

    def lock_exclusive(slot : Int32, count : Int32 = 1) : Bool
      true
    end

    def unlock(slot : Int32, count : Int32 = 1) : Nil
    end

    def close(delete : Bool) : Nil
      @file.close
    end
  end
end
