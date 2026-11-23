require "../../../src/grant/sqlite_engine"

# An in-memory file system for the engine that records every write, sync,
# truncate and delete, and builds the files a crash at any point would have
# left: every prefix of the recorded operations, and for each prefix the
# variants where writes not yet synced are lost or torn at 512-byte sectors
# (https://www.sqlite.org/atomiccommit.html §2, "Hardware Assumptions").
class SQLiteEngineCrashFileSystem < Grant::SQLiteEngine::FileSystem
  SECTOR = 512

  enum OperationKind
    Write
    Sync
    Truncate
    Delete
  end

  record Operation, kind : OperationKind, path : String, offset : Int64 = 0_i64, bytes : Bytes = Bytes.empty

  # How unsynced writes fare in a crash state.
  enum Variant
    # Every write reached the disk.
    Kept
    # No write since its file's last sync reached the disk.
    Lost
    # Only the file written last kept its unsynced writes; the others lost
    # theirs (the disk reordered writes between files).
    LostExceptLastFile
    # The last unsynced write reached the disk only in its first half of
    # sectors.
    TornHead
    # The last unsynced write reached the disk only in its second half.
    TornTail
  end

  getter files : Hash(String, Bytes)
  getter list_of_operations = [] of Operation
  getter? recording = false

  def initialize(@files : Hash(String, Bytes) = {} of String => Bytes)
  end

  def open(path : String) : Grant::SQLiteEngine::DatabaseFile
    @files[path] = Bytes.empty unless @files.has_key?(path)
    CrashFile.new(self, path)
  end

  def exists?(path : String) : Bool
    @files.has_key?(path)
  end

  def delete(path : String) : Nil
    return unless @files.has_key?(path)
    @files.delete(path)
    record_operation(Operation.new(OperationKind::Delete, path))
  end

  # A copy of every file, the state before the operations to be recorded.
  def snapshot : Hash(String, Bytes)
    @files.transform_values(&.dup)
  end

  def start_recording : Nil
    @list_of_operations.clear
    @recording = true
  end

  def stop_recording : Array(Operation)
    @recording = false
    @list_of_operations.dup
  end

  protected def record_operation(operation : Operation) : Nil
    @list_of_operations << operation if @recording
  end

  protected def write(path : String, offset : Int64, bytes : Bytes) : Nil
    content = @files[path]? || Bytes.empty
    finish = offset + bytes.size
    if finish > content.size
      grown = Bytes.new(finish.to_i32)
      grown.copy_from(content.to_unsafe, content.size)
      content = grown
    end
    (content + offset).copy_from(bytes.to_unsafe, bytes.size)
    @files[path] = content
    record_operation(Operation.new(OperationKind::Write, path, offset, bytes.dup))
  end

  protected def truncate(path : String, size : Int64) : Nil
    content = @files[path]? || Bytes.empty
    resized = Bytes.new(size.to_i32)
    resized.copy_from(content.to_unsafe, Math.min(content.size, size.to_i32))
    @files[path] = resized
    record_operation(Operation.new(OperationKind::Truncate, path, size))
  end

  protected def sync(path : String) : Nil
    record_operation(Operation.new(OperationKind::Sync, path))
  end

  # The files a crash after the first *count* of *operations* leaves,
  # starting from *start*, with unsynced writes treated as *variant* says.
  def self.crash_state(start : Hash(String, Bytes), operations : Array(Operation), count : Int32, variant : Variant) : Hash(String, Bytes)?
    prefix = operations[0, count]
    unsynced = Set(Int32).new
    prefix.each_with_index do |operation, position|
      if operation.kind.write?
        unsynced << position
      elsif operation.kind.sync?
        prefix.each_with_index { |earlier, index| unsynced.delete(index) if index < position && earlier.path == operation.path }
      end
    end
    torn = variant.torn_head? || variant.torn_tail? ? unsynced.max? : nil
    return if (variant.torn_head? || variant.torn_tail?) && (torn.nil? || prefix[torn].bytes.size <= SECTOR)
    return if (variant.lost? || variant.lost_except_last_file?) && unsynced.empty?
    last_written = prefix.reverse.find(&.kind.write?).try(&.path)
    state = SQLiteEngineCrashFileSystem.new(start.transform_values(&.dup))
    prefix.each_with_index do |operation, position|
      case operation.kind
      when .write?
        next if variant.lost? && unsynced.includes?(position)
        next if variant.lost_except_last_file? && unsynced.includes?(position) && operation.path != last_written
        bytes = operation.bytes
        offset = operation.offset
        if position == torn
          sectors = (bytes.size + SECTOR - 1) // SECTOR
          head = (sectors // 2) * SECTOR
          if variant.torn_head?
            bytes = bytes[0, head]
          else
            bytes = bytes[head..]
            offset += head
          end
        end
        state.write(operation.path, offset, bytes)
      when .truncate?
        state.truncate(operation.path, operation.offset)
      when .delete?
        state.files.delete(operation.path)
      end
    end
    state.files
  end

  # One open file. Locks always succeed: the simulator runs one connection.
  class CrashFile < Grant::SQLiteEngine::DatabaseFile
    getter lock_level : Grant::SQLiteEngine::LockLevel = Grant::SQLiteEngine::LockLevel::None

    def initialize(@file_system : SQLiteEngineCrashFileSystem, @path : String)
    end

    def size : Int64
      (@file_system.files[@path]? || Bytes.empty).size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      content = @file_system.files[@path]? || Bytes.empty
      return 0 if offset >= content.size
      available = Math.min(buffer.size.to_i64, content.size - offset).to_i32
      buffer.copy_from((content + offset).to_unsafe, available)
      available
    end

    def write_at(offset : Int64, bytes_to_write : Bytes) : Nil
      @file_system.write(@path, offset, bytes_to_write)
    end

    def sync : Nil
      @file_system.sync(@path)
    end

    def truncate(size : Int64) : Nil
      @file_system.truncate(@path, size)
    end

    def close : Nil
    end

    def lock(level : Grant::SQLiteEngine::LockLevel) : Bool
      @lock_level = level if level > @lock_level
      true
    end

    def unlock(level : Grant::SQLiteEngine::LockLevel) : Nil
      @lock_level = level if level < @lock_level
    end

    def reserved_elsewhere? : Bool
      false
    end
  end
end
