module Grant::SQLiteEngine
  # The free pages of a database (fileformat2.html §1.5): trunk pages, each
  # listing leaf pages, chained from the header.
  struct Freelist
    getter list_of_trunk_pages : Array(UInt32)
    getter list_of_leaf_pages : Array(UInt32)

    def initialize(@list_of_trunk_pages : Array(UInt32), @list_of_leaf_pages : Array(UInt32))
    end

    # Every free page, trunk and leaf.
    def page_count : Int32
      @list_of_trunk_pages.size + @list_of_leaf_pages.size
    end

    # Walks the trunk chain. Raises when a page number is out of range, a
    # trunk repeats, a trunk lists more leaves than fit on it, or the chain
    # holds more pages than the header counts.
    def self.read(pager : Pager, header : DatabaseHeader) : Freelist
      trunks = [] of UInt32
      leaves = [] of UInt32
      expected = header.freelist_page_count.to_i64
      max_leaves_per_trunk = pager.usable_size // 4 - 2
      seen = Set(UInt32).new
      trunk = header.first_freelist_trunk_page
      while trunk != 0
        pager.check_page_number(trunk)
        raise CorruptDatabase.new("freelist trunk chain visits page #{trunk} twice", trunk) unless seen.add?(trunk)
        trunks << trunk
        data = pager.read_page(trunk)
        leaf_count = big_endian_u32(data, 4)
        if leaf_count > max_leaves_per_trunk
          raise CorruptDatabase.new("freelist trunk lists #{leaf_count} leaves, more than #{max_leaves_per_trunk}", trunk)
        end
        leaf_count.times do |index|
          leaf = big_endian_u32(data, 8 + index.to_i32 * 4)
          pager.check_page_number(leaf)
          leaves << leaf
        end
        if trunks.size + leaves.size > expected
          raise CorruptDatabase.new("freelist holds more than the #{expected} pages the header counts", trunk)
        end
        trunk = big_endian_u32(data, 0)
      end
      if trunks.size + leaves.size != expected
        raise CorruptDatabase.new("freelist holds #{trunks.size + leaves.size} pages, the header counts #{expected}", 1_u32)
      end
      new(trunks, leaves)
    end

    protected def self.big_endian_u32(data : Bytes, offset : Int32) : UInt32
      (data[offset].to_u32 << 24) | (data[offset + 1].to_u32 << 16) | (data[offset + 2].to_u32 << 8) | data[offset + 3]
    end
  end
end
