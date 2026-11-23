module Grant::SQLiteEngine
  # Files held in memory, for a `:memory:` database: private to the
  # connection that opened it, so every lock is granted at once and a sync
  # does nothing.
  class MemoryFileSystem < FileSystem
    @files = {} of String => MemoryFile

    def open(path : String) : DatabaseFile
      @files[path] ||= MemoryFile.new
    end

    def exists?(path : String) : Bool
      @files.has_key?(path)
    end

    def delete(path : String) : Nil
      @files.delete(path)
    end
  end

  # One in-memory file, grown in place as it is written.
  class MemoryFile < DatabaseFile
    @bytes = Bytes.empty
    @size = 0_i64
    @lock_level = LockLevel::None

    def size : Int64
      @size
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      return 0 if offset >= @size
      count = Math.min(buffer.size.to_i64, @size - offset).to_i32
      buffer.copy_from((@bytes.to_unsafe + offset), count)
      count
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      finish = offset + bytes_to_write.size
      if finish > @bytes.size
        grown = Bytes.new(Math.max(finish, @bytes.size.to_i64 * 2).to_i32)
        grown.copy_from(@bytes.to_unsafe, @size.to_i32)
        @bytes = grown
      end
      (@bytes.to_unsafe + offset).copy_from(bytes_to_write.to_unsafe, bytes_to_write.size)
      @size = finish if finish > @size
    end

    def sync : Nil
    end

    def truncate(size : Int64) : Nil
      @size = Math.min(size, @size)
    end

    def close : Nil
    end

    def lock(level : LockLevel) : Bool
      @lock_level = level if level > @lock_level
      true
    end

    def unlock(level : LockLevel) : Nil
      @lock_level = level
    end

    def lock_level : LockLevel
      @lock_level
    end

    def reserved_elsewhere? : Bool
      false
    end
  end
end
