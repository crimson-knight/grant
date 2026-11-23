module Grant::SQLiteEngine
  # Where the reader's bytes come from: a file opened read-only, or bytes
  # already in memory (used by the damage fuzzer and by callers that hold a
  # database in memory).
  abstract class ByteSource
    # Total size in bytes.
    abstract def size : Int64

    # Fills *buffer* from *offset*. Returns the number of bytes read, which is
    # less than the buffer only at the end of the source.
    abstract def read_at(offset : Int64, buffer : Bytes) : Int32

    # Releases the source.
    abstract def close : Nil
  end

  # A file opened read-only. Nothing is ever written through it.
  class FileByteSource < ByteSource
    getter size : Int64

    def initialize(path : String | Path)
      @file = File.open(path, "rb")
      @file.read_buffering = false
      @size = @file.size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      return 0 if offset >= @size
      @file.pos = offset
      total = 0
      while total < buffer.size
        count = @file.read(buffer[total..])
        break if count == 0
        total += count
      end
      total
    end

    def close : Nil
      @file.close
    end
  end

  # Bytes held in memory.
  class MemoryByteSource < ByteSource
    def initialize(@bytes : Bytes)
    end

    def size : Int64
      @bytes.size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      return 0 if offset >= @bytes.size
      available = Math.min(buffer.size.to_i64, @bytes.size.to_i64 - offset).to_i32
      buffer.copy_from(@bytes[offset.to_i32, available].to_unsafe, available)
      available
    end

    def close : Nil
    end
  end
end
