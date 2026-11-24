module Grant::SQLiteEngine::Query
  # PRAGMA fullfsync and PRAGMA checkpoint_fullfsync (pragma.html): the
  # two flags of a connection that make its syncs `SyncMode::Full` ones.
  # Both are off by default, read as one row named after the PRAGMA, and
  # act on the main database and every attached one (setAllPagerFlags).
  module DurabilityPragmas
    FULLFSYNC            = "fullfsync"
    CHECKPOINT_FULLFSYNC = "checkpoint_fullfsync"

    # The column names of `PRAGMA name`, or nil for another PRAGMA: a row
    # when the flag is read, none when it is set.
    def self.columns(name : String, value : String?) : Array(String)?
      return unless name == FULLFSYNC || name == CHECKPOINT_FULLFSYNC
      value ? [] of String : [name]
    end

    # Reads the flag *name*, or sets it from *value* and hands both flags
    # to the pagers. Inside a transaction the new value is kept and read
    # back, and reaches the pagers with the next setting made outside one,
    # as in C.
    def self.rows(session : Session, name : String, value : String?) : Array(Array(Value))
      return [[on?(session, name) ? 1_i64 : 0_i64] of Value] unless value
      session.pragma_values[name] = flag?(value) ? 1_i64 : 0_i64
      unless session.in_transaction?
        share_with(session, session.database.pager)
        session.list_of_attached.each { |(_name, database)| share_with(session, database.pager) }
      end
      [] of Array(Value)
    end

    # Hands the session's two flags to *pager* (a database just attached
    # starts with them, as attachFunc passes db->flags).
    def self.share_with(session : Session, pager : Pager) : Nil
      pager.fullfsync = on?(session, FULLFSYNC)
      pager.checkpoint_fullfsync = on?(session, CHECKPOINT_FULLFSYNC)
    end

    private def self.on?(session : Session, name : String) : Bool
      session.pragma_values[name]? == 1_i64
    end

    # sqlite3GetBoolean with a default of off: a value that starts with a
    # digit is on when the low byte of the integer it starts with is not
    # zero; otherwise only on, yes and true (in any case) are on.
    def self.flag?(text : String) : Bool
      return false if text.empty?
      return (leading_integer(text) & 0xff) != 0 if text[0].ascii_number?
      {"on", "yes", "true"}.any? { |word| text.compare(word, case_insensitive: true) == 0 }
    end

    # sqlite3Atoi (sqlite3GetInt32) of text that starts with a digit: the
    # decimal digits it starts with, or up to eight hexadecimal digits
    # after 0x; 0 for a number past the 32-bit signed range.
    private def self.leading_integer(text : String) : Int32
      if text.size > 2 && text[0] == '0' && text[1].in?('x', 'X') && text[2].hex?
        digits = text[2..].lstrip('0')
        count = digits.each_char.take_while(&.hex?).size
        return 0 if count > 8
        number = count == 0 ? 0_i64 : digits[0, count].to_i64(16)
        return number > Int32::MAX ? 0 : number.to_i32
      end
      digits = text.lstrip('0')
      count = digits.each_char.take_while(&.ascii_number?).size
      return 0 if count == 0 || count > 10
      number = digits[0, count].to_i64
      number > Int32::MAX ? 0 : number.to_i32
    end
  end
end
