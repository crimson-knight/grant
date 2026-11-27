# The rollback journal's format as C SQLite's pager reads it, written
# without Grant's engine so a spec can check the engine against it: walk
# the segments of a journal (a header, then its page records), and lay
# segments out byte for byte into a new journal.
#
# A segment's header sits at a multiple of the sector size the journal's
# first header names (journalHdrOffset), and holds the magic, the record
# count (nRec), the checksum nonce, the page count before the transaction,
# the sector size and the page size. C writes a new segment each time it
# syncs the journal in the middle of a transaction, when it spills dirty
# pages to the database file.
module SQLiteEngineHotJournal
  MAGIC = Bytes[0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]
  # The sector size a pager takes before it reads a journal's first header:
  # 512 on unix and Windows with powersafe overwrite (setSectorSize).
  PAGER_SECTOR_SIZE = 512
  # nRec of a segment whose record count the file's size tells.
  RECORD_COUNT_FROM_SIZE = 0xffff_ffff_u32

  # One page record: the page number, the page's original image and the
  # checksum stored after it.
  record PageRecord, page_number : UInt32, image : Bytes, checksum : UInt32 do
    # A record whose checksum is right for *nonce*.
    def self.checked(nonce : UInt32, page_number : UInt32, image : Bytes) : self
      new(page_number, image, SQLiteEngineHotJournal.checksum(nonce, image))
    end
  end

  # One header and the records that follow it. *record_count* is the nRec
  # field as written, which may say more or fewer records than
  # *list_of_records* holds (0 for an unsynced segment, 0xffffffff for one
  # whose count the file size tells).
  class Segment
    property offset : Int64
    property record_count : UInt32
    property nonce : UInt32
    property initial_page_count : UInt32
    property sector_size : UInt32
    property page_size : UInt32
    property list_of_records : Array(PageRecord)
    property magic : Bytes

    def initialize(@record_count, @nonce, @initial_page_count, @sector_size, @page_size,
                   @list_of_records = [] of PageRecord, @offset = 0_i64, @magic = MAGIC)
    end

    # True when C has synced this segment (its count is set), as it does
    # before it spills pages to the database file.
    def synced? : Bool
      record_count != 0 && record_count != RECORD_COUNT_FROM_SIZE
    end

    def copy : Segment
      Segment.new(record_count, nonce, initial_page_count, sector_size, page_size, list_of_records.dup, offset, magic)
    end
  end

  # pager_cksum: the nonce plus every 200th byte of the page, counting down
  # from 200 bytes before its end.
  def self.checksum(nonce : UInt32, image : Bytes) : UInt32
    sum = nonce
    index = image.size - 200
    while index > 0
      sum &+= image[index]
      index -= 200
    end
    sum
  end

  # The next header's offset after *offset* (journalHdrOffset).
  def self.header_offset(offset : Int64, sector_size : Int64) : Int64
    offset == 0 ? 0_i64 : ((offset - 1) // sector_size + 1) * sector_size
  end

  # The segments of *journal*, walked as pager_playback walks a hot
  # journal: a header wherever one fits and starts with the magic, then as
  # many whole records as its nRec says (all the rest of the file for
  # 0xffffffff, from the file size as C computes it). Checksums are kept as
  # stored, not checked. Stops at the first header without the magic.
  def self.list_of_segments(journal : Bytes) : Array(Segment)
    list = [] of Segment
    offset = 0_i64
    sector_size = PAGER_SECTOR_SIZE.to_i64
    page_size = 0_i64
    loop do
      offset = header_offset(offset, sector_size)
      break if offset + sector_size > journal.size
      break unless journal[offset, 8] == MAGIC
      record_count = get_u32(journal, offset + 8)
      nonce = get_u32(journal, offset + 12)
      initial_page_count = get_u32(journal, offset + 16)
      if list.empty?
        sector_size = get_u32(journal, offset + 20).to_i64
        page_size = get_u32(journal, offset + 24).to_i64
        break if sector_size < 32 || page_size < 512
      end
      segment = Segment.new(record_count, nonce, initial_page_count, sector_size.to_u32, page_size.to_u32, offset: offset)
      list << segment
      offset += sector_size
      count = record_count
      count = ((journal.size - sector_size) // (page_size + 8)).to_u32 if count == RECORD_COUNT_FROM_SIZE
      count.times do
        break if offset + page_size + 8 > journal.size
        image = journal[offset + 4, page_size].dup
        segment.list_of_records << PageRecord.new(get_u32(journal, offset), image, get_u32(journal, offset + 4 + page_size))
        offset += page_size + 8
      end
      break if segment.list_of_records.size < count
    end
    list
  end

  # The segments C has synced in the journal at *path* (each one before a
  # spill), or 0 when there is no journal.
  def self.synced_segment_count(path : String) : Int32
    return 0 unless File.exists?(path)
    list_of_segments(File.open(path, "rb", &.getb_to_end)).count(&.synced?)
  end

  # *list_of_segments* laid out as a journal: each header at the next
  # multiple of the first segment's sector size, the header sector's
  # remaining bytes zero, the records as given. A segment's own offset is
  # ignored.
  def self.encode(list_of_segments : Array(Segment)) : Bytes
    io = IO::Memory.new
    first = list_of_segments.first? || return Bytes.empty
    sector_size = first.sector_size.to_i64
    list_of_segments.each do |segment|
      header_at = header_offset(io.pos.to_i64, sector_size)
      io.write(Bytes.new(header_at - io.pos)) if header_at > io.pos
      header = Bytes.new(sector_size)
      header.copy_from(segment.magic.to_unsafe, 8)
      put_u32(header, 8, segment.record_count)
      put_u32(header, 12, segment.nonce)
      put_u32(header, 16, segment.initial_page_count)
      put_u32(header, 20, segment.sector_size)
      put_u32(header, 24, segment.page_size)
      io.write(header)
      segment.list_of_records.each do |page_record|
        field = Bytes.new(4)
        put_u32(field, 0, page_record.page_number)
        io.write(field)
        io.write(page_record.image)
        put_u32(field, 0, page_record.checksum)
        io.write(field)
      end
    end
    io.to_slice
  end

  def self.get_u32(bytes : Bytes, offset : Int64) : UInt32
    IO::ByteFormat::BigEndian.decode(UInt32, bytes[offset, 4])
  end

  def self.put_u32(bytes : Bytes, offset : Int32, value : UInt32) : Nil
    IO::ByteFormat::BigEndian.encode(value, bytes[offset, 4])
  end
end
