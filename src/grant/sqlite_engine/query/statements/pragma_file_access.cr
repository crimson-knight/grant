module Grant::SQLiteEngine::Query
  # Which PRAGMAs read the database file, and when, as pragma.c decides it
  # for C SQLite 3.51.0. A PRAGMA that reads nothing takes no lock, so it
  # runs while another connection holds one: `PRAGMA busy_timeout = 5000`
  # must succeed before any lock can be waited for.
  module PragmaFileAccess
    # The PRAGMAs pragma.h marks PragFlg_NeedSchema: compiling one loads
    # the schema, which opens a read transaction (and waits for it through
    # the busy handler).
    LIST_OF_PRAGMAS_COMPILED_WITH_THE_SCHEMA = %w[
      auto_vacuum cache_size default_cache_size foreign_key_check foreign_key_list incremental_vacuum index_info
      index_list index_xinfo integrity_check journal_mode max_page_count optimize page_count quick_check stats
      synchronous table_info table_list table_xinfo wal_checkpoint
    ]

    # The PRAGMAs that compile without the schema and read the database
    # header when they run (PragTyp_HEADER_VALUE's OP_Transaction and
    # OP_ReadCookie, and the page size and text encoding the header holds).
    LIST_OF_PRAGMAS_READING_THE_HEADER = %w[
      application_id data_version encoding freelist_count page_size schema_version user_version
    ]

    # Whether compiling `PRAGMA name` reads the schema.
    def self.compile_reads_schema?(name : String) : Bool
      LIST_OF_PRAGMAS_COMPILED_WITH_THE_SCHEMA.includes?(name.downcase)
    end

    # Whether running `PRAGMA name` reads a page of the database. Every
    # other PRAGMA (a connection setting, or a name C does not know)
    # touches no file.
    def self.run_reads_file?(name : String) : Bool
      lowered = name.downcase
      LIST_OF_PRAGMAS_COMPILED_WITH_THE_SCHEMA.includes?(lowered) || LIST_OF_PRAGMAS_READING_THE_HEADER.includes?(lowered)
    end

    # Whether running *statement* reads a page of the database, for a
    # statement that is not transaction control.
    def self.run_reads_file?(statement : SQL::Statement) : Bool
      return true unless statement.is_a?(SQL::Pragma)
      run_reads_file?(statement.name.value)
    end

    # The PRAGMA name in *sql* (lowercase), read without the parser, when
    # the statement is spelled `PRAGMA name` or `PRAGMA schema.name` with
    # bare names; nil for any other text.
    def self.name_in(sql : String) : String?
      bytes = sql.to_slice
      start = skip_space(bytes, 0)
      finish = word_end(bytes, start)
      return unless finish - start == 6
      "PRAGMA".to_slice.each_with_index do |byte, index|
        return unless bytes[start + index] & 0xdf_u8 == byte
      end
      start = skip_space(bytes, finish)
      finish = word_end(bytes, start)
      return if finish == start
      following = skip_space(bytes, finish)
      if following < bytes.size && bytes[following] == '.'.ord
        start = skip_space(bytes, following + 1)
        finish = word_end(bytes, start)
        return if finish == start
      end
      return if finish < bytes.size && bytes[finish] >= 0x80_u8
      String.new(bytes[start, finish - start]).downcase
    end

    private def self.word_end(bytes : Bytes, start : Int32) : Int32
      position = start
      while position < bytes.size && word_byte?(bytes[position])
        position += 1
      end
      position
    end

    private def self.skip_space(bytes : Bytes, start : Int32) : Int32
      position = start
      while position < bytes.size && space?(bytes[position])
        position += 1
      end
      position
    end

    private def self.word_byte?(byte : UInt8) : Bool
      (byte >= 'a'.ord && byte <= 'z'.ord) || (byte >= 'A'.ord && byte <= 'Z'.ord) || (byte >= '0'.ord && byte <= '9'.ord) || byte == '_'.ord
    end

    # The whitespace SQLite's tokenizer skips.
    private def self.space?(byte : UInt8) : Bool
      byte == ' '.ord || byte == '\t'.ord || byte == '\n'.ord || byte == '\f'.ord || byte == '\r'.ord
    end
  end
end
