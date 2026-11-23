module Grant::SQLiteEngine
  # Bounds the reader enforces on untrusted files. Each cites the part of the
  # specification it comes from.
  module Limits
    # fileformat2.html §1.3.2: the page size is a power of two from 512 to 65,536.
    MIN_PAGE_SIZE =    512
    MAX_PAGE_SIZE = 65_536

    # fileformat2.html §1.3.4: the usable size (page size minus reserved
    # bytes) may not be less than 480.
    MIN_USABLE_SIZE = 480

    # A b-tree is at most this deep before the reader calls it corrupt.
    # SQLite's own cursor stack is 20 deep (BTCURSOR_MAX_DEPTH); 64 leaves room
    # for any file C SQLite can write.
    MAX_BTREE_DEPTH = 64

    # fileformat2.html §1.6: a varint is at most nine bytes.
    MAX_VARINT_BYTES = 9

    # limits.html: SQLITE_MAX_LENGTH, the largest text or blob value.
    MAX_VALUE_BYTES = 1_000_000_000

    # limits.html: SQLITE_MAX_COLUMN, columns in a table or index record.
    MAX_COLUMNS = 2_000

    # fileformat2.html §1.4: SQLite reserves page numbers up to 2^32 - 2.
    MAX_PAGE_NUMBER = 4_294_967_294_u32
  end
end
