module Grant::SQLiteEngine::Query
  # One date and time as SQLite's date functions hold it while they work:
  # date.c's `DateTime` struct of SQLite 3.51.0, with its parsers
  # (parseDateOrTime, parseModifier) and its conversions between the julian
  # day number and the calendar fields (computeJD, computeYMD, computeHMS).
  # Every step follows the C source, including its integer truncation and
  # the order of its floating-point operations, so results match C bit for
  # bit.
  #
  # ```
  # moment = DateTime.new
  # moment.parse_date_or_time(DateTime::Text.new("2026-11-24 10:11:12.123456".to_slice), DateTime::Call.new(session, "date")) # => true
  # moment.compute_julian_day
  # moment.julian_day_milliseconds # => 212630955072123
  # ```
  class DateTime
    # The julian day number of 9999-12-31 23:59:59.999, in milliseconds.
    LARGEST_JULIAN_DAY_MILLISECONDS = 464_269_060_799_999_i64
    # The julian day number of 1970-01-01 00:00:00, in milliseconds.
    UNIX_EPOCH_JULIAN_DAY_MILLISECONDS = 210_866_760_000_000_i64
    MILLISECONDS_PER_DAY               =          86_400_000_i64

    # What a call gives the parsers beyond its arguments: the statement's
    # reading of the clock, and whether the call sits where SQLite demands
    # deterministic functions. *function_name* is nil for the CURRENT_DATE,
    # CURRENT_TIME and CURRENT_TIMESTAMP keywords, which C never runs as
    # pure functions.
    struct Call
      def initialize(@session : Session, @function_name : String?)
      end

      # sqlite3StmtCurrentTime: 'now' for the running statement, as
      # milliseconds of julian day.
      def current_time : Int64
        @session.statement_current_time
      end

      # sqlite3NotPureFunc: 'now', `localtime` and `utc` depend on more
      # than the arguments, so a CHECK constraint, a generated column or
      # an index refuses them.
      def require_nondeterministic_use_allowed : Nil
        name = @function_name || return
        context = @session.deterministic_context || return
        raise SQLError.new("non-deterministic use of #{name}() in #{context}")
      end
    end

    # The bytes of a text value as C reads them: a string that ends at its
    # first zero byte, where every position past the end reads as zero.
    struct Text
      def initialize(@bytes : Bytes, @start : Int32 = 0)
      end

      # The text of *value* as sqlite3_value_text gives it; nil for NULL.
      def self.of(value : Value) : Text?
        bytes = case value
                when Nil    then return
                when Bytes  then value
                when String then value.to_slice
                else             ValueSemantics.text_of_number(value).to_slice
                end
        cut = bytes.index(0_u8)
        new(cut ? bytes[0, cut] : bytes)
      end

      @[AlwaysInline]
      def [](index : Int32) : UInt8
        position = @start + index
        position < @bytes.size ? @bytes.unsafe_fetch(position) : 0_u8
      end

      def +(count : Int32) : Text
        Text.new(@bytes, @start + count)
      end

      # strlen.
      def size : Int32
        Math.max(@bytes.size - @start, 0)
      end

      def to_slice : Bytes
        @start >= @bytes.size ? Bytes.empty : @bytes[@start, @bytes.size - @start]
      end

      def to_slice(count : Int32) : Bytes
        slice = to_slice
        count < slice.size ? slice[0, count] : slice
      end

      # sqlite3_stricmp(z, word) == 0: the whole text is *word*, ASCII case
      # aside. *word* is lower case.
      def same_word?(word : String) : Bool
        size == word.bytesize && starts_with_word?(word)
      end

      # sqlite3_strnicmp(z, word, word's size) == 0.
      def starts_with_word?(word : String) : Bool
        word.to_slice.each_with_index do |expected, index|
          return false unless DateTime.lower(self[index]) == expected
        end
        true
      end
    end

    # One `NNN unit` modifier (aXformType): the unit, the largest NNN it
    # takes and its length in seconds. C holds the last two as `float`.
    record Shift, unit : String, limit : Float64, seconds : Float64

    SHIFTS = [
      Shift.new("second", 4.6427e+14_f32.to_f64, 1.0),
      Shift.new("minute", 7.7379e+12_f32.to_f64, 60.0),
      Shift.new("hour", 1.2897e+11_f32.to_f64, 3600.0),
      Shift.new("day", 5373485.0_f32.to_f64, 86400.0),
      Shift.new("month", 176546.0_f32.to_f64, 2592000.0),
      Shift.new("year", 14713.0_f32.to_f64, 31536000.0),
    ]
    MONTH_SHIFT = 4
    YEAR_SHIFT  = 5

    # The largest value of each getDigits range letter, a to f.
    DIGIT_MAXIMUMS = [12, 14, 24, 31, 59, 14712]

    # The julian day number times 86400000 (iJD).
    property julian_day_milliseconds = 0_i64
    property year = 0
    property month = 0
    property day = 0
    property hour = 0
    property minute = 0
    # Timezone offset in minutes (tz).
    property timezone_minutes = 0
    property seconds = 0.0
    property? has_valid_julian_day = false
    property? has_valid_date = false
    property? has_valid_time = false
    # Days past the end of the month, for `floor` (nFloor).
    property floor_days = 0
    # A raw number waits in `seconds` (rawS).
    property? holds_raw_number = false
    property? has_error = false
    # Show fractional seconds in the output (useSubsec).
    property? shows_subseconds = false
    property? known_utc = false
    property? known_local = false

    @[AlwaysInline]
    def self.lower(byte : UInt8) : UInt8
      byte >= 0x41_u8 && byte <= 0x5a_u8 ? byte + 0x20_u8 : byte
    end

    # C's cast of a double to a 64-bit integer, as arm64 and the values the
    # callers guard give it: truncation, saturating, zero for NaN.
    def self.truncate(real : Float64) : Int64
      return 0_i64 if real.nan?
      return Int64::MAX if real >= 9.223372036854775807e18
      return Int64::MIN if real <= -9.223372036854775808e18
      real.to_i64!
    end

    # C's cast of a double to an int.
    def self.truncate_to_int(real : Float64) : Int32
      truncate(real).clamp(Int32::MIN.to_i64, Int32::MAX.to_i64).to_i32
    end

    # validJulianDay.
    def self.julian_day_in_range?(milliseconds : Int64) : Bool
      milliseconds >= 0 && milliseconds <= LARGEST_JULIAN_DAY_MILLISECONDS
    end

    # getDigits: reads the integers *format* describes from *text*. Each
    # integer is four format characters: digit count, smallest value, a
    # letter for the largest value, and the separator that follows (none
    # after the last). Returns how many it read, and their values.
    def self.digits(text : Text, format : String) : {Int32, StaticArray(Int32, 3)}
      values = StaticArray(Int32, 3).new(0)
      pattern = format.to_slice
      count = 0
      position = 0
      offset = 0
      loop do
        digit_count = pattern[offset] - 0x30
        minimum = (pattern[offset + 1] - 0x30).to_i32
        maximum = DIGIT_MAXIMUMS[pattern[offset + 2] - 0x61]
        separator = offset + 3 < pattern.size ? pattern[offset + 3] : 0_u8
        value = 0
        digit_count.times do
          byte = text[position]
          return {count, values} unless NumericText.digit?(byte)
          value = value * 10 + (byte - 0x30)
          position += 1
        end
        if value < minimum || value > maximum || (separator != 0 && separator != text[position])
          return {count, values}
        end
        values[count] = value
        position += 1
        count += 1
        offset += 4
        break if separator == 0
      end
      {count, values}
    end

    # datetimeError: everything cleared, the error flag set.
    def fail : Nil
      clear
      @has_error = true
    end

    # memset(p, 0, sizeof(*p)).
    def clear : Nil
      @julian_day_milliseconds = 0_i64
      @year = @month = @day = @hour = @minute = @timezone_minutes = @floor_days = 0
      @seconds = 0.0
      @has_valid_julian_day = @has_valid_date = @has_valid_time = false
      @holds_raw_number = @has_error = @shows_subseconds = @known_utc = @known_local = false
    end

    # clearYMD_HMS_TZ.
    def forget_calendar_fields : Nil
      @has_valid_date = false
      @has_valid_time = false
      @timezone_minutes = 0
    end

    # parseTimezone: `[+-]HH:MM` or `Z` at the end of a time. True on a
    # parse error; nothing at all is not an error.
    def parse_timezone(text : Text) : Bool
      position = 0
      while NumericText.space?(text[position])
        position += 1
      end
      @timezone_minutes = 0
      byte = text[position]
      sign = 0
      if byte == '-'.ord
        sign = -1
      elsif byte == '+'.ord
        sign = 1
      elsif byte == 'Z'.ord || byte == 'z'.ord
        position += 1
        @known_local = false
        @known_utc = true
      else
        return byte != 0
      end
      if sign != 0
        position += 1
        count, values = DateTime.digits(text + position, "20b:20e")
        return true unless count == 2
        position += 5
        @timezone_minutes = sign * (values[1] + values[0] * 60)
        if @timezone_minutes == 0
          @known_local = false
          @known_utc = true
        end
      end
      while NumericText.space?(text[position])
        position += 1
      end
      text[position] != 0
    end

    # parseHhMmSs: HH:MM, HH:MM:SS or HH:MM:SS.FFFF. True on a parse error.
    def parse_time(text : Text) : Bool
      count, values = DateTime.digits(text, "20c:20e")
      return true unless count == 2
      parsed_hour = values[0]
      parsed_minute = values[1]
      parsed_second = 0
      fraction = 0.0
      position = 5
      if text[position] == ':'.ord
        position += 1
        count, values = DateTime.digits(text + position, "20e")
        return true unless count == 1
        parsed_second = values[0]
        position += 2
        if text[position] == '.'.ord && NumericText.digit?(text[position + 1])
          scale = 1.0
          position += 1
          while NumericText.digit?(text[position])
            fraction = fraction * 10.0 + text[position].to_f64 - 48.0
            scale *= 10.0
            position += 1
          end
          fraction /= scale
          # Cut off so that sub-millisecond rounding cannot reach the next
          # second.
          fraction = 0.999 if fraction > 0.999
        end
      end
      @has_valid_julian_day = false
      @holds_raw_number = false
      @has_valid_time = true
      @hour = parsed_hour
      @minute = parsed_minute
      @seconds = parsed_second + fraction
      parse_timezone(text + position)
    end

    # computeJD: the julian day number from the calendar fields (Meeus,
    # page 61), always Gregorian.
    def compute_julian_day : Nil
      return if @has_valid_julian_day
      if @has_valid_date
        shifted_year = @year
        shifted_month = @month
        day_of_month = @day
      else
        shifted_year = 2000
        shifted_month = 1
        day_of_month = 1
      end
      if shifted_year < -4713 || shifted_year > 9999 || @holds_raw_number
        fail
        return
      end
      if shifted_month <= 2
        shifted_year -= 1
        shifted_month += 12
      end
      century = (shifted_year + 4800).tdiv(100)
      gregorian_correction = 38 - century + century.tdiv(4)
      x1 = (36525 * (shifted_year + 4716)).tdiv(100)
      x2 = (306001 * (shifted_month + 1)).tdiv(10000)
      @julian_day_milliseconds = DateTime.truncate(((x1 + x2 + day_of_month + gregorian_correction) - 1524.5) * 86400000)
      @has_valid_julian_day = true
      if @has_valid_time
        @julian_day_milliseconds &+= (@hour * 3600000 + @minute * 60000).to_i64 &+ DateTime.truncate(@seconds * 1000 + 0.5)
        if @timezone_minutes != 0
          @julian_day_milliseconds &-= @timezone_minutes * 60000
          @has_valid_date = false
          @has_valid_time = false
          @timezone_minutes = 0
          @known_utc = true
          @known_local = false
        end
      end
    end

    # computeFloor: how many days the day of the month runs past the end
    # of its month.
    def compute_floor : Nil
      @floor_days = if @day <= 28
                      0
                    elsif (1 << @month) & 0x15aa != 0
                      0
                    elsif @month != 2
                      @day == 31 ? 1 : 0
                    elsif @year.remainder(4) != 0 || (@year.remainder(100) == 0 && @year.remainder(400) != 0)
                      @day - 28
                    else
                      @day - 29
                    end
    end

    # parseYyyyMmDd: YYYY-MM-DD with an optional time. True on a parse
    # error.
    def parse_date(text : Text) : Bool
      negative = text[0] == '-'.ord
      position = negative ? 1 : 0
      count, values = DateTime.digits(text + position, "40f-21a-21d")
      return true unless count == 3
      position += 10
      while NumericText.space?(text[position]) || text[position] == 'T'.ord
        position += 1
      end
      if !parse_time(text + position)
        # The time is read.
      elsif text[position] == 0
        @has_valid_time = false
      else
        return true
      end
      @has_valid_julian_day = false
      @has_valid_date = true
      @year = negative ? -values[0] : values[0]
      @month = values[1]
      @day = values[2]
      compute_floor
      compute_julian_day if @timezone_minutes != 0
      false
    end

    # setDateTimeToCurrent. True when the clock gave no time.
    def take_current_time(call : Call) : Bool
      call.require_nondeterministic_use_allowed
      @julian_day_milliseconds = call.current_time
      return true unless @julian_day_milliseconds > 0
      @has_valid_julian_day = true
      @known_utc = true
      @known_local = false
      forget_calendar_fields
      false
    end

    # setRawDateNumber: a number that is a julian day when it is in range,
    # and may yet turn out to be a unix time.
    def take_raw_number(real : Float64) : Nil
      @seconds = real
      @holds_raw_number = true
      if real >= 0.0 && real < 5373484.5
        @julian_day_milliseconds = DateTime.truncate(real * 86400000.0 + 0.5)
        @has_valid_julian_day = true
      end
    end

    # parseDateOrTime: a date, a time, 'now', a number, or 'subsec'. True
    # on a parse error.
    def parse_date_or_time(text : Text, call : Call) : Bool
      return false unless parse_date(text)
      return false unless parse_time(text)
      return take_current_time(call) if text.same_word?("now")
      number = NumericText.ato_f(text.to_slice)
      if number.kind > 0
        take_raw_number(number.value)
        return false
      end
      if text.same_word?("subsec") || text.same_word?("subsecond")
        @shows_subseconds = true
        return take_current_time(call)
      end
      true
    end

    # computeYMD: year, month and day from the julian day number.
    def compute_date : Nil
      return if @has_valid_date
      if !@has_valid_julian_day
        @year = 2000
        @month = 1
        @day = 1
      elsif !DateTime.julian_day_in_range?(@julian_day_milliseconds)
        fail
        return
      else
        julian_day_number = (@julian_day_milliseconds + 43200000).tdiv(MILLISECONDS_PER_DAY).to_i32
        century_correction = DateTime.truncate_to_int((julian_day_number + 32044.75) / 36524.25) - 52
        corrected_day = julian_day_number + 1 + century_correction - (century_correction + 100).tdiv(4) + 25
        shifted_day = corrected_day + 1524
        shifted_year = DateTime.truncate_to_int((shifted_day - 122.1) / 365.25)
        days_before_year = (36525 * (shifted_year & 32767)).tdiv(100)
        shifted_month = DateTime.truncate_to_int((shifted_day - days_before_year) / 30.6001)
        x1 = DateTime.truncate_to_int(30.6001 * shifted_month)
        @day = shifted_day - days_before_year - x1
        @month = shifted_month < 14 ? shifted_month - 1 : shifted_month - 13
        @year = @month > 2 ? shifted_year - 4716 : shifted_year - 4715
      end
      @has_valid_date = true
    end

    # computeHMS: hour, minute and seconds from the julian day number.
    def compute_time : Nil
      return if @has_valid_time
      compute_julian_day
      day_milliseconds = (@julian_day_milliseconds &+ 43200000).remainder(MILLISECONDS_PER_DAY).to_i32
      @seconds = day_milliseconds.remainder(60000) / 1000.0
      day_minutes = day_milliseconds.tdiv(60000)
      @minute = day_minutes.remainder(60)
      @hour = day_minutes.tdiv(60)
      @holds_raw_number = false
      @has_valid_time = true
    end

    # computeYMD_HMS.
    def compute_date_and_time : Nil
      compute_date
      compute_time
    end

    # toLocaltime: the value, taken as UTC, moved to the process's local
    # time with localtime_r, as C does. Years outside 1970 to 2037 map to
    # an equivalent year inside that range and back.
    def move_to_local_time : Nil
      compute_julian_day
      year_difference = 0
      if @julian_day_milliseconds < 210_866_760_000_000_i64 || @julian_day_milliseconds > 213_014_145_600_000_i64
        mapped = dup
        mapped.compute_date_and_time
        year_difference = (2000 + mapped.year.remainder(4)) - mapped.year
        mapped.year += year_difference
        mapped.has_valid_julian_day = false
        mapped.compute_julian_day
        unix_seconds = mapped.julian_day_milliseconds.tdiv(1000) &- 210_866_760_000_i64
      else
        unix_seconds = @julian_day_milliseconds.tdiv(1000) &- 210_866_760_000_i64
      end
      seconds_since_epoch = LibC::TimeT.new!(unix_seconds)
      local = uninitialized LibC::Tm
      if LibC.localtime_r(pointerof(seconds_since_epoch), pointerof(local)).null?
        raise SQLError.new("local time unavailable")
      end
      @year = local.tm_year + 1900 - year_difference
      @month = local.tm_mon + 1
      @day = local.tm_mday
      @hour = local.tm_hour
      @minute = local.tm_min
      @seconds = local.tm_sec + @julian_day_milliseconds.remainder(1000) * 0.001
      @has_valid_date = true
      @has_valid_time = true
      @has_valid_julian_day = false
      @holds_raw_number = false
      @timezone_minutes = 0
      @has_error = false
    end

    # autoAdjustDate: a raw number outside the julian day range is taken as
    # a unix time.
    def adjust_raw_number : Nil
      if !@holds_raw_number || @has_valid_julian_day
        @holds_raw_number = false
      elsif @seconds >= -210_866_760_000_i64 && @seconds <= 253_402_300_799_i64
        real = @seconds * 1000.0 + 210866760000000.0
        forget_calendar_fields
        @julian_day_milliseconds = DateTime.truncate(real + 0.5)
        @has_valid_julian_day = true
        @holds_raw_number = false
      end
    end

    # parseModifier: applies modifier *text*, argument number *index* of
    # the call (the first modifier is 1). True when the modifier is not
    # one SQLite knows or does not apply.
    def apply_modifier(text : Text, index : Int32, call : Call) : Bool
      case DateTime.lower(text[0])
      when 'a'.ord
        return true unless text.same_word?("auto")
        return true if index > 1
        adjust_raw_number
        false
      when 'c'.ord
        return true unless text.same_word?("ceiling")
        compute_julian_day
        forget_calendar_fields
        @floor_days = 0
        false
      when 'f'.ord
        return true unless text.same_word?("floor")
        compute_julian_day
        @julian_day_milliseconds &-= @floor_days * MILLISECONDS_PER_DAY
        forget_calendar_fields
        false
      when 'j'.ord
        return true unless text.same_word?("julianday")
        return true if index > 1
        return true unless @has_valid_julian_day && @holds_raw_number
        @holds_raw_number = false
        false
      when 'l'.ord
        return true unless text.same_word?("localtime")
        call.require_nondeterministic_use_allowed
        move_to_local_time unless @known_local
        @known_utc = false
        @known_local = true
        false
      when 'u'.ord
        apply_unixepoch_or_utc(text, index, call)
      when 'w'.ord
        apply_weekday(text)
      when 's'.ord
        apply_start_of_or_subsecond(text)
      when '+'.ord, '-'.ord, '0'.ord..'9'.ord
        apply_shift(text)
      else
        true
      end
    end

    private def apply_unixepoch_or_utc(text : Text, index : Int32, call : Call) : Bool
      if text.same_word?("unixepoch") && @holds_raw_number
        return true if index > 1
        real = @seconds * 1000.0 + 210866760000000.0
        return true unless real >= 0.0 && real < 464269060800000.0
        forget_calendar_fields
        @julian_day_milliseconds = DateTime.truncate(real + 0.5)
        @has_valid_julian_day = true
        @holds_raw_number = false
        return false
      end
      return true unless text.same_word?("utc")
      call.require_nondeterministic_use_allowed
      return false if @known_utc
      # The local time whose UTC is wanted: guess, see what local time the
      # guess gives, and correct by the difference.
      compute_julian_day
      original = @julian_day_milliseconds
      guess = original
      error = 0_i64
      attempts = 0
      loop do
        candidate = DateTime.new
        guess &-= error
        candidate.julian_day_milliseconds = guess
        candidate.has_valid_julian_day = true
        candidate.move_to_local_time
        candidate.compute_julian_day
        error = candidate.julian_day_milliseconds &- original
        break if error == 0
        attempts += 1
        break if attempts > 3
      end
      clear
      @julian_day_milliseconds = guess
      @has_valid_julian_day = true
      @known_utc = true
      @known_local = false
      false
    end

    # `weekday N`: forward to the next day that is weekday N (0 Sunday).
    private def apply_weekday(text : Text) : Bool
      return true unless text.starts_with_word?("weekday ")
      number = NumericText.ato_f((text + 8).to_slice)
      return true unless number.kind > 0
      real = number.value
      return true unless real >= 0.0 && real < 7.0
      target = real.to_i32
      return true unless target == real
      compute_date_and_time
      @timezone_minutes = 0
      @has_valid_julian_day = false
      compute_julian_day
      weekday = (@julian_day_milliseconds &+ 129600000).tdiv(MILLISECONDS_PER_DAY).remainder(7)
      weekday -= 7 if weekday > target
      @julian_day_milliseconds &+= (target - weekday) * MILLISECONDS_PER_DAY
      forget_calendar_fields
      false
    end

    # `start of month`, `start of year`, `start of day`, `subsec` and
    # `subsecond`.
    private def apply_start_of_or_subsecond(text : Text) : Bool
      unless text.starts_with_word?("start of ")
        return true unless text.same_word?("subsec") || text.same_word?("subsecond")
        @shows_subseconds = true
        return false
      end
      return true if !@has_valid_julian_day && !@has_valid_date && !@has_valid_time
      unit = text + 9
      compute_date
      @has_valid_time = true
      @hour = @minute = 0
      @seconds = 0.0
      @holds_raw_number = false
      @timezone_minutes = 0
      @has_valid_julian_day = false
      if unit.same_word?("month")
        @day = 1
        false
      elsif unit.same_word?("year")
        @month = 1
        @day = 1
        false
      else
        !unit.same_word?("day")
      end
    end

    # Carries a month outside 1 to 12 into the year.
    private def carry_months : Nil
      carried = @month > 0 ? (@month - 1).tdiv(12) : (@month - 12).tdiv(12)
      @year += carried
      @month -= carried * 12
    end

    # The modifiers that start with a sign or a digit: `NNN unit`,
    # `±YYYY-MM-DD` with an optional time, and `±HH:MM[:SS[.FFF]]`.
    private def apply_shift(text : Text) : Bool
      first = text[0]
      number_size = 1
      while text[number_size] != 0
        byte = text[number_size]
        break if byte == ':'.ord || NumericText.space?(byte)
        if byte == '-'.ord
          break if number_size == 5 && DateTime.digits(text + 1, "40f")[0] == 1
          break if number_size == 6 && DateTime.digits(text + 1, "50f")[0] == 1
        end
        number_size += 1
      end
      number = NumericText.ato_f(text.to_slice(number_size))
      return true unless number.kind > 0
      real = number.value
      time_text = text
      if text[number_size] == '-'.ord
        # ±YYYY-MM-DD adds or subtracts years, months and days; the month
        # is 0 to 11 and the day 0 to 30.
        return true unless first == '+'.ord || first == '-'.ord
        if number_size == 5
          count, values = DateTime.digits(text + 1, "40f-20a-20d")
          return true unless count == 3
        else
          count, values = DateTime.digits(text + 1, "50f-20a-20d")
          return true unless count == 3
          text += 1
        end
        years, months, days = values[0], values[1], values[2]
        return true if months >= 12 || days >= 31
        compute_date_and_time
        @has_valid_julian_day = false
        if first == '-'.ord
          @year -= years
          @month -= months
          days = -days
        else
          @year += years
          @month += months
        end
        carry_months
        compute_floor
        compute_julian_day
        @has_valid_time = false
        @has_valid_date = false
        @julian_day_milliseconds &+= days.to_i64 * MILLISECONDS_PER_DAY
        return false if text[11] == 0
        return true unless NumericText.space?(text[11]) && DateTime.digits(text + 12, "20c:20e")[0] == 2
        time_text = text + 12
        number_size = 2
      end
      if time_text[number_size] == ':'.ord
        # ±HH:MM[:SS[.FFF]] adds or subtracts that much time.
        time_text += 1 unless NumericText.digit?(time_text[0])
        offset = DateTime.new
        return true if offset.parse_time(time_text)
        offset.compute_julian_day
        milliseconds = offset.julian_day_milliseconds &- 43200000
        milliseconds &-= milliseconds.tdiv(MILLISECONDS_PER_DAY) * MILLISECONDS_PER_DAY
        milliseconds = 0_i64 &- milliseconds if first == '-'.ord
        compute_julian_day
        forget_calendar_fields
        @julian_day_milliseconds &+= milliseconds
        return false
      end
      apply_unit_shift(text + number_size, real)
    end

    # `NNN unit` with NNN already read as *real*; *text* starts after it.
    private def apply_unit_shift(text : Text, real : Float64) : Bool
      position = 0
      while NumericText.space?(text[position])
        position += 1
      end
      unit = text + position
      size = unit.size
      return true if size < 3 || size > 10
      size -= 1 if DateTime.lower(unit[size - 1]) == 's'.ord
      compute_julian_day
      rounder = real < 0 ? -0.5 : 0.5
      @floor_days = 0
      unknown = true
      SHIFTS.each_with_index do |shift, index|
        next unless shift.unit.bytesize == size && unit.starts_with_word?(shift.unit)
        next unless real > -shift.limit && real < shift.limit
        if index == MONTH_SHIFT
          compute_date_and_time
          @month += real.to_i32
          carry_months
          compute_floor
          @has_valid_julian_day = false
          real -= real.to_i32
        elsif index == YEAR_SHIFT
          compute_date_and_time
          @year += real.to_i32
          compute_floor
          @has_valid_julian_day = false
          real -= real.to_i32
        end
        compute_julian_day
        @julian_day_milliseconds &+= DateTime.truncate(real * 1000.0 * shift.seconds + rounder)
        unknown = false
        break
      end
      forget_calendar_fields
      unknown
    end

    # daysAfterJan01: the zero-based day of the year.
    def days_after_january_first : Int32
      january_first = dup
      january_first.has_valid_julian_day = false
      january_first.month = 1
      january_first.day = 1
      january_first.compute_julian_day
      (@julian_day_milliseconds &- january_first.julian_day_milliseconds &+ 43200000).tdiv(MILLISECONDS_PER_DAY).to_i32!
    end

    # daysAfterMonday: 0 Monday to 6 Sunday.
    def days_after_monday : Int32
      (@julian_day_milliseconds &+ 43200000).tdiv(MILLISECONDS_PER_DAY).to_i32!.remainder(7)
    end

    # daysAfterSunday: 0 Sunday to 6 Saturday.
    def days_after_sunday : Int32
      (@julian_day_milliseconds &+ 129600000).tdiv(MILLISECONDS_PER_DAY).to_i32!.remainder(7)
    end

    # The Thursday of this value's ISO week, whose year and day number give
    # %G, %g and %V.
    def thursday_of_same_week : DateTime
      thursday = dup
      thursday.julian_day_milliseconds &+= (3 - days_after_monday) * MILLISECONDS_PER_DAY
      thursday.has_valid_date = false
      thursday.compute_date
      thursday
    end
  end
end
