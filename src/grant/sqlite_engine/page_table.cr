module Grant::SQLiteEngine
  # Page buffers by page number, for the pager's page cache and its changed
  # pages: an open-addressed table with linear probing, so a lookup is a
  # multiply, a shift and (nearly always) one comparison, where a `Hash`
  # hashes the key and goes through its index and entry arrays. Page number
  # 0 never names a page, so it marks an empty slot. Deleting moves the
  # entries after it back (no tombstones), so a lookup stops at the first
  # empty slot.
  #
  # Iteration follows slot order, not insertion order; every caller that
  # needs an order sorts the page numbers.
  class PageTable
    MINIMUM_CAPACITY = 16

    getter size = 0
    @capacity : Int32
    @shift : Int32
    @keys : Pointer(UInt32)
    @values : Pointer(Bytes)

    def initialize
      @capacity = MINIMUM_CAPACITY
      @shift = 32 - MINIMUM_CAPACITY.trailing_zeros_count
      @keys = Pointer(UInt32).malloc(@capacity)
      @values = Pointer(Bytes).malloc(@capacity)
    end

    # Empty slots for *capacity* entries, a power of two.
    private def allocate(capacity : Int32) : Nil
      @capacity = capacity
      @shift = 32 - capacity.trailing_zeros_count
      @keys = Pointer(UInt32).malloc(capacity)
      @values = Pointer(Bytes).malloc(capacity)
    end

    def empty? : Bool
      @size == 0
    end

    def []?(page_number : UInt32) : Bytes?
      mask = @capacity - 1
      slot = slot_of(page_number)
      loop do
        key = @keys[slot]
        return @values[slot] if key == page_number
        return if key == 0
        slot = (slot + 1) & mask
      end
    end

    def has_key?(page_number : UInt32) : Bool
      !self[page_number]?.nil?
    end

    def []=(page_number : UInt32, buffer : Bytes) : Bytes
      raise ArgumentError.new("page number 0 names no page") if page_number == 0
      grow if (@size + 1) * 4 > @capacity * 3
      mask = @capacity - 1
      slot = slot_of(page_number)
      loop do
        key = @keys[slot]
        if key == page_number
          @values[slot] = buffer
          return buffer
        end
        break if key == 0
        slot = (slot + 1) & mask
      end
      @keys[slot] = page_number
      @values[slot] = buffer
      @size += 1
      buffer
    end

    # Removes *page_number*, returning its buffer (nil when it was absent).
    def delete(page_number : UInt32) : Bytes?
      mask = @capacity - 1
      slot = slot_of(page_number)
      loop do
        key = @keys[slot]
        return if key == 0
        break if key == page_number
        slot = (slot + 1) & mask
      end
      removed = @values[slot]
      # Backward-shift deletion: each later entry of the probe run whose
      # home slot does not lie between the hole and itself moves into the
      # hole.
      hole = slot
      following = (slot + 1) & mask
      while (key = @keys[following]) != 0
        home = slot_of(key)
        if (following - home) & mask >= (following - hole) & mask
          @keys[hole] = key
          @values[hole] = @values[following]
          hole = following
        end
        following = (following + 1) & mask
      end
      @keys[hole] = 0_u32
      @values[hole] = Bytes.empty
      @size -= 1
      removed
    end

    # Empties the table. One that grew large for a big transaction goes
    # back to the minimum size, so later small transactions clear little.
    def clear : Nil
      return if @size == 0
      if @capacity > MINIMUM_CAPACITY * 64
        allocate(MINIMUM_CAPACITY)
      else
        @keys.clear(@capacity)
        @values.clear(@capacity)
      end
      @size = 0
    end

    def each(& : UInt32, Bytes ->) : Nil
      @capacity.times do |slot|
        key = @keys[slot]
        yield key, @values[slot] unless key == 0
      end
    end

    def each_key(& : UInt32 ->) : Nil
      @capacity.times do |slot|
        key = @keys[slot]
        yield key unless key == 0
      end
    end

    def each_value(& : Bytes ->) : Nil
      @capacity.times do |slot|
        yield @values[slot] unless @keys[slot] == 0
      end
    end

    # Removes every entry the block returns true for.
    def reject!(& : UInt32, Bytes -> Bool) : Nil
      list_of_rejected = [] of UInt32
      each { |page_number, buffer| list_of_rejected << page_number if yield page_number, buffer }
      list_of_rejected.each { |page_number| delete(page_number) }
    end

    # Fibonacci hashing: the top bits of the page number times 2^32/φ.
    private def slot_of(page_number : UInt32) : Int32
      ((page_number &* 0x9e3779b9_u32) >> @shift).to_i32
    end

    private def grow : Nil
      old_keys = @keys
      old_values = @values
      old_capacity = @capacity
      allocate(@capacity * 2)
      @size = 0
      old_capacity.times do |slot|
        key = old_keys[slot]
        self[key] = old_values[slot] unless key == 0
      end
    end
  end
end
