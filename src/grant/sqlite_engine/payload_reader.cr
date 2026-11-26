module Grant::SQLiteEngine
  # Assembles a cell's whole payload: the bytes on its page followed by the
  # overflow chain (fileformat2.html §1.6, "Cell Payload Overflow Pages").
  module PayloadReader
    # Returns the payload. A payload that fits on its page is returned as a
    # slice of the page, without copying.
    def self.read(pager : Pager, page : BTreePage, location : PayloadLocation) : Bytes
      local = local_part(page.data, location)
      return local unless location.spills?
      payload = Bytes.new(location.total_size)
      payload.copy_from(local.to_unsafe, local.size)
      written = local.size
      overflow_capacity = pager.usable_size - 4
      # The chain needs exactly this many pages; a longer chain is never
      # followed, so a cycle cannot loop forever, and a repeated page in the
      # pages it does follow is reported.
      needed = ((location.total_size.to_i64 - written + overflow_capacity - 1) // overflow_capacity).to_i32
      seen = Set(UInt32).new
      next_page = location.first_overflow_page
      needed.times do
        if next_page == 0
          raise CorruptDatabase.new("overflow chain of the cell ends #{location.total_size - written} bytes early", location.page_number)
        end
        unless seen.add?(next_page)
          raise CorruptDatabase.new("overflow chain visits page #{next_page} twice", location.page_number)
        end
        pager.check_page_number(next_page)
        overflow = pager.read_page(next_page)
        chunk = Math.min(overflow_capacity, location.total_size - written)
        (payload + written).copy_from((overflow + 4).to_unsafe, chunk)
        written += chunk
        next_page = (overflow[0].to_u32 << 24) | (overflow[1].to_u32 << 16) | (overflow[2].to_u32 << 8) | overflow[3]
      end
      payload
    end

    # The part of the payload kept on the page, as a view of *page_bytes*. A
    # b-tree seek reads one for every key it compares, so the bounds are
    # checked here, inline, instead of through `Slice#[]`.
    @[AlwaysInline]
    private def self.local_part(page_bytes : Bytes, location : PayloadLocation) : Bytes
      offset = location.local_offset
      size = location.local_size
      raise IndexError.new unless 0 <= offset && 0 <= size && size <= page_bytes.size - offset
      Slice.new(page_bytes.to_unsafe + offset, size, read_only: page_bytes.read_only?)
    end
  end
end
