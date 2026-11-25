{% if flag?(:win32) %}
  require "c/memoryapi"
  require "c/sysinfoapi"

  module Grant::SQLiteEngine
    # The wal-index of a database on Windows, as os_win.c's winShm: each
    # 32 KiB region is mapped with CreateFileMapping and MapViewOfFile, and
    # the lock slots and the dead man switch are LockFileEx locks on the
    # same bytes of the `-shm` file C SQLite locks (120 to 128).
    #
    # Connections of one process share one mapping and one handle, which
    # holds the dead man switch (winShmNode). Each connection takes the slot
    # locks through a handle of its own, because Windows locks belong to the
    # handle: two connections of one process then exclude each other just as
    # two processes do.
    class WindowsSharedMemory < SharedMemory
      include MappedRegions

      # The handle, mappings and views every connection of this process
      # shares for one `-shm` file (winShmNode).
      class Node
        getter handle : LibC::HANDLE
        getter path : String
        # The first byte of each region, inside its view.
        getter list_of_regions = [] of Pointer(UInt8)
        getter mutex = Mutex.new(:reentrant)
        property reference_count = 0
        @list_of_mappings = [] of LibC::HANDLE
        @list_of_views = [] of Pointer(Void)

        def initialize(@path : String, @handle : LibC::HANDLE)
        end

        # winShmMap: maps the next region. A view must start on a multiple
        # of the allocation granularity (64 KiB), so it starts that far
        # before the region and the region's address is offset into it.
        def map_next_region(mapping_size : Int64) : Nil
          mapping = LibC.CreateFileMappingA(@handle, nil, LibC::DWORD.new(LibC::PAGE_READWRITE),
            LibC::DWORD.new!(mapping_size >> 32), LibC::DWORD.new!(mapping_size), nil)
          raise Error.new("could not map the wal-index file (CreateFileMapping: #{WinError.value})") if mapping.null?
          offset = @list_of_regions.size.to_i64 * REGION_SIZE
          shift = offset % Node.allocation_granularity
          view = LibC.MapViewOfFile(mapping, LibC::DWORD.new(LibC::FILE_MAP_WRITE | LibC::FILE_MAP_READ),
            LibC::DWORD.new!((offset - shift) >> 32), LibC::DWORD.new!(offset - shift), LibC::SizeT.new(REGION_SIZE + shift))
          if view.null?
            error = WinError.value
            WindowsHandle.close(mapping)
            raise Error.new("could not map the wal-index file (MapViewOfFile: #{error})")
          end
          @list_of_mappings << mapping
          @list_of_views << view
          @list_of_regions << view.as(UInt8*) + shift
        end

        def unmap : Nil
          @list_of_views.each { |view| LibC.UnmapViewOfFile(view) }
          @list_of_mappings.each { |mapping| WindowsHandle.close(mapping) }
          @list_of_views.clear
          @list_of_mappings.clear
          @list_of_regions.clear
        end

        def self.allocation_granularity : Int64
          information = LibC::SYSTEM_INFO.new
          LibC.GetNativeSystemInfo(pointerof(information))
          information.dwAllocationGranularity.to_i64
        end
      end

      @@nodes = {} of String => Node
      @@nodes_mutex = Mutex.new

      @node : Node
      @lock_handle : LibC::HANDLE
      @shared_mask = 0
      @exclusive_mask = 0
      @closed = false

      # Opens (creating) *path* and takes the dead man switch: the first
      # connection of any process empties the file, so a wal-index left by a
      # crash is rebuilt. Raises `Busy` while another process holds the
      # switch exclusively (it is emptying the file).
      def initialize(path : String)
        @lock_handle = WindowsHandle.open(path)
        @node = WindowsSharedMemory.node_for(path, @lock_handle)
      end

      # The node every connection of this process shares for *path*, opened
      # (taking the dead man switch) by the first of them. Closes
      # *lock_handle* when that fails.
      protected def self.node_for(path : String, lock_handle : LibC::HANDLE) : Node
        @@nodes_mutex.synchronize do
          key = File.realpath(path)
          node = @@nodes[key]?
          unless node
            handle = WindowsHandle.open(key)
            node = Node.new(key, handle)
            begin
              take_dead_man_switch(node)
            rescue error
              WindowsHandle.close(handle)
              raise error
            end
            @@nodes[key] = node
          end
          node.reference_count += 1
          node
        end
      rescue error
        WindowsHandle.close(lock_handle)
        raise error
      end

      # winLockSharedMemory: an exclusive lock on the switch means no other
      # connection has the file open, so it is emptied; then every
      # connection holds the switch shared.
      private def self.take_dead_man_switch(node : Node) : Nil
        if WindowsHandle.lock(node.handle, DEAD_MAN_BYTE, 1, exclusive: true)
          begin
            WindowsHandle.truncate(node.handle, 0)
          ensure
            WindowsHandle.unlock(node.handle, DEAD_MAN_BYTE, 1)
          end
        end
        raise Busy.new unless WindowsHandle.lock(node.handle, DEAD_MAN_BYTE, 1, exclusive: false)
      end

      def map_region(index : Int32, grow : Bool) : Bool
        node = @node
        node.mutex.synchronize do
          return true if index < node.list_of_regions.size
          needed = (index.to_i64 + 1) * REGION_SIZE
          if WindowsHandle.size(node.handle) < needed
            return false unless grow
            WindowsHandle.truncate(node.handle, needed)
          end
          while node.list_of_regions.size <= index
            node.map_next_region(needed)
          end
          true
        end
      end

      def mapped_region_count : Int32
        @node.list_of_regions.size
      end

      # The first byte of mapped region *index*.
      def region_address(index : Int32) : UInt8*
        @node.list_of_regions.unsafe_fetch(index)
      end

      # winShmLock, shared branch. A slot this connection holds exclusively
      # is refused, as the POSIX wal-index refuses it.
      def lock_shared(slot : Int32) : Bool
        mask = 1 << slot
        return true if @shared_mask & mask != 0
        return false if @exclusive_mask & mask != 0
        return false unless WindowsHandle.lock(@lock_handle, LOCK_BASE + slot, 1, exclusive: false)
        @shared_mask |= mask
        true
      end

      # winShmLock, exclusive branch. Each slot is its own one-byte lock, so
      # any later unlock of any of them matches the range Windows locked;
      # when one is refused, the ones this call took are released again.
      def lock_exclusive(slot : Int32, count : Int32 = 1) : Bool
        taken = [] of Int32
        slot.upto(slot + count - 1) do |index|
          mask = 1 << index
          next if @exclusive_mask & mask != 0
          if @shared_mask & mask != 0 || !WindowsHandle.lock(@lock_handle, LOCK_BASE + index, 1, exclusive: true)
            taken.each { |held| WindowsHandle.unlock(@lock_handle, LOCK_BASE + held, 1) }
            return false
          end
          taken << index
        end
        taken.each { |index| @exclusive_mask |= 1 << index }
        true
      end

      # winShmLock, unlock branch.
      def unlock(slot : Int32, count : Int32 = 1) : Nil
        slot.upto(slot + count - 1) do |index|
          mask = 1 << index
          next if (@shared_mask | @exclusive_mask) & mask == 0
          WindowsHandle.unlock(@lock_handle, LOCK_BASE + index, 1)
          @shared_mask &= ~mask
          @exclusive_mask &= ~mask
        end
      end

      # winShmUnmap and winShmPurge: this connection's lock handle closes;
      # the last connection of the process unmaps the regions and closes
      # the shared handle (which drops the dead man switch), then removes
      # the file when *delete* is set. Windows removes no file a handle
      # still has mapped, so the file goes after the handles.
      def close(delete : Bool) : Nil
        return if @closed
        @closed = true
        unlock(0, SLOT_COUNT)
        WindowsHandle.close(@lock_handle)
        @@nodes_mutex.synchronize do
          node = @node
          node.reference_count -= 1
          if node.reference_count == 0
            node.unmap
            WindowsHandle.unlock(node.handle, DEAD_MAN_BYTE, 1)
            WindowsHandle.close(node.handle)
            @@nodes.delete(node.path)
            remove_file(node.path) if delete
          end
        end
      end

      # winShmPurge removes the file as a benign failure: a `-shm` file
      # another process still has open stays, and is emptied by the next
      # first opener.
      private def remove_file(path : String) : Nil
        WindowsHandle.delete(path)
      rescue File::Error
      end
    end
  end
{% end %}
