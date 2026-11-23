module Grant::SQLiteEngine
  # Pointer-map pages of an auto-vacuum database (fileformat2.html §1.7): for
  # each page, what kind of page it is and its parent.
  module PointerMap
    # Pointer-map entry types (fileformat2.html §1.7).
    enum EntryType : UInt8
      Unused        = 0
      RootPage      = 1
      FreePage      = 2
      FirstOverflow = 3
      LaterOverflow = 4
      NonRootBTree  = 5
    end

    record Entry, page_number : UInt32, entry_type : EntryType, parent_page : UInt32

    ENTRY_SIZE = 5

    # Reads every pointer-map page. Returns no entries for a database without
    # auto-vacuum.
    def self.read(pager : Pager, header : DatabaseHeader) : Array(Entry)
      entries = [] of Entry
      return entries unless header.has_pointer_map_pages?
      per_page = pager.usable_size // ENTRY_SIZE
      map_page = 2_u32
      while map_page <= pager.page_count
        data = pager.read_page(map_page)
        per_page.times do |slot|
          described = map_page.to_u64 + 1 + slot
          break if described > pager.page_count
          code = data[slot * ENTRY_SIZE]
          entry_type = EntryType.from_value?(code)
          raise CorruptDatabase.new("pointer-map entry #{slot} has type #{code}", map_page) unless entry_type
          parent = (data[slot * ENTRY_SIZE + 1].to_u32 << 24) | (data[slot * ENTRY_SIZE + 2].to_u32 << 16) |
                   (data[slot * ENTRY_SIZE + 3].to_u32 << 8) | data[slot * ENTRY_SIZE + 4]
          entries << Entry.new(described.to_u32, entry_type, parent)
        end
        next_map = map_page.to_u64 + per_page + 1
        break if next_map > UInt32::MAX
        map_page = next_map.to_u32
      end
      entries
    end
  end
end
