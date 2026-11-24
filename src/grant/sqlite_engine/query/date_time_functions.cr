module Grant::SQLiteEngine::Query
  # The time one run of a statement reads as 'now': C reads the clock at
  # the first use and gives that reading to every later use in the same
  # run (sqlite3StmtCurrentTime, Vdbe.iCurrentTime).
  class StatementClock
    @julian_day_milliseconds = 0_i64

    # The run's time, as milliseconds of julian day.
    def julian_day_milliseconds : Int64
      @julian_day_milliseconds = StatementClock.read if @julian_day_milliseconds == 0
      @julian_day_milliseconds
    end

    # Starts another run: the next use reads the clock again.
    def reset : Nil
      @julian_day_milliseconds = 0_i64
    end

    def self.read : Int64
      Time.utc.to_unix_ms + DateTime::UNIX_EPOCH_JULIAN_DAY_MILLISECONDS
    end
  end

  class Session
    # The clock of the statement that is running, set by PreparedQuery
    # around each step.
    property statement_clock : StatementClock? = nil

    # Where the expression being evaluated sits when SQLite demands
    # deterministic functions there ("a CHECK constraint", "a generated
    # column", "an index"), set by RowProgram; nil anywhere else.
    property deterministic_context : String? = nil

    # sqlite3StmtCurrentTime: 'now' for the running statement.
    def statement_current_time : Int64
      clock = @statement_clock
      clock ? clock.julian_day_milliseconds : StatementClock.read
    end
  end

  # SQLite's date and time functions (lang_datefunc.html): date(), time(),
  # datetime(), julianday(), unixepoch(), strftime() and timediff(), and
  # the functions behind CURRENT_DATE, CURRENT_TIME and CURRENT_TIMESTAMP,
  # each ported from date.c of SQLite 3.51.0.
  #
  # ```
  # DateTimeFunctions.date(["2026-01-31", "+1 month"] of Value, DateTime::Call.new(session, "date")) # => "2026-03-03"
  # ```
  module DateTimeFunctions
    alias Definition = ScalarFunctions::Definition

    def self.list_of_definitions : Array(Definition)
      [
        definition("julianday", 0, -1) { |arguments, session| julianday(arguments, DateTime::Call.new(session, "julianday")) },
        definition("unixepoch", 0, -1) { |arguments, session| unixepoch(arguments, DateTime::Call.new(session, "unixepoch")) },
        definition("date", 0, -1) { |arguments, session| date(arguments, DateTime::Call.new(session, "date")) },
        definition("time", 0, -1) { |arguments, session| time(arguments, DateTime::Call.new(session, "time")) },
        definition("datetime", 0, -1) { |arguments, session| datetime(arguments, DateTime::Call.new(session, "datetime")) },
        definition("strftime", 0, -1) { |arguments, session| strftime(arguments, DateTime::Call.new(session, "strftime")) },
        definition("timediff", 2, 2) { |arguments, session| timediff(arguments, DateTime::Call.new(session, "timediff")) },
        definition("current_time", 0, 0) { |arguments, session| time(arguments, DateTime::Call.new(session, nil)) },
        definition("current_timestamp", 0, 0) { |arguments, session| datetime(arguments, DateTime::Call.new(session, nil)) },
        definition("current_date", 0, 0) { |arguments, session| date(arguments, DateTime::Call.new(session, nil)) },
      ]
    end

    private def self.definition(name : String, minimum : Int32, maximum : Int32,
                                &implementation : Array(Value), Session -> Value) : Definition
      Definition.new(name, minimum, maximum, ->(arguments : Array(Value), context : ScalarFunctions::CallContext) { implementation.call(arguments, context.session) })
    end

    # The expression of the CURRENT_DATE, CURRENT_TIME or CURRENT_TIMESTAMP
    # keyword: a call of its function, so each run reads the clock.
    def self.keyword_expression(kind : SQL::LiteralKind) : Expr
      name = if kind.current_time?
               "current_time"
             elsif kind.current_date?
               "current_date"
             else
               "current_timestamp"
             end
      found = ScalarFunctions.lookup(name, 0) || raise Error.new("date function #{name} missing")
      FunctionExpr.new(found, [] of Expr)
    end

    # isDate: the time value *arguments* describe, a time value followed by
    # modifiers ('now' without any argument); nil where C gives NULL.
    def self.moment(arguments : Array(Value), call : DateTime::Call, first : Int32 = 0, count : Int32 = arguments.size - first) : DateTime?
      moment = DateTime.new
      if count == 0
        return if moment.take_current_time(call)
        return finish(moment, count)
      end
      value = arguments[first]
      if value.is_a?(Int64) || value.is_a?(Float64)
        moment.take_raw_number(value.to_f64)
      else
        text = DateTime::Text.of(value) || return
        return if moment.parse_date_or_time(text, call)
      end
      index = 1
      while index < count
        modifier = DateTime::Text.of(arguments[first + index]) || return
        return if moment.apply_modifier(modifier, index, call)
        index += 1
      end
      finish(moment, count)
    end

    private def self.finish(moment : DateTime, count : Int32) : DateTime?
      moment.compute_julian_day
      return if moment.has_error? || !DateTime.julian_day_in_range?(moment.julian_day_milliseconds)
      # A lone YYYY-MM-DD past the 28th is normalized: 2023-02-31 reads
      # as 2023-03-03.
      moment.has_valid_date = false if count == 1 && moment.has_valid_date? && moment.day > 28
      moment
    end

    def self.julianday(arguments : Array(Value), call : DateTime::Call) : Value
      moment = moment(arguments, call) || return
      moment.julian_day_milliseconds / 86400000.0
    end

    def self.unixepoch(arguments : Array(Value), call : DateTime::Call) : Value
      moment = moment(arguments, call) || return
      if moment.shows_subseconds?
        (moment.julian_day_milliseconds - DateTime::UNIX_EPOCH_JULIAN_DAY_MILLISECONDS) / 1000.0
      else
        moment.julian_day_milliseconds.tdiv(1000) - 210_866_760_000_i64
      end
    end

    def self.datetime(arguments : Array(Value), call : DateTime::Call) : Value
      moment = moment(arguments, call) || return
      moment.compute_date_and_time
      String.build(25) do |io|
        write_date(io, moment)
        io << ' '
        write_time(io, moment)
      end
    end

    def self.time(arguments : Array(Value), call : DateTime::Call) : Value
      moment = moment(arguments, call) || return
      moment.compute_time
      String.build(12) { |io| write_time(io, moment) }
    end

    def self.date(arguments : Array(Value), call : DateTime::Call) : Value
      moment = moment(arguments, call) || return
      moment.compute_date
      String.build(11) { |io| write_date(io, moment) }
    end

    private def self.digit(io : IO, value : Int32) : Nil
      io << ('0' + value.remainder(10))
    end

    # YYYY-MM-DD, with a minus sign in front of a negative year.
    private def self.write_date(io : IO, moment : DateTime) : Nil
      year = moment.year
      if year < 0
        io << '-'
        year = -year
      end
      digit(io, year.tdiv(1000))
      digit(io, year.tdiv(100))
      digit(io, year.tdiv(10))
      digit(io, year)
      io << '-'
      digit(io, moment.month.tdiv(10))
      digit(io, moment.month)
      io << '-'
      digit(io, moment.day.tdiv(10))
      digit(io, moment.day)
    end

    # HH:MM:SS, or HH:MM:SS.SSS with subseconds on.
    private def self.write_time(io : IO, moment : DateTime) : Nil
      digit(io, moment.hour.tdiv(10))
      digit(io, moment.hour)
      io << ':'
      digit(io, moment.minute.tdiv(10))
      digit(io, moment.minute)
      io << ':'
      if moment.shows_subseconds?
        milliseconds = DateTime.truncate_to_int(1000.0 * moment.seconds + 0.5)
        digit(io, milliseconds.tdiv(10000))
        digit(io, milliseconds.tdiv(1000))
        io << '.'
        digit(io, milliseconds.tdiv(100))
        digit(io, milliseconds.tdiv(10))
        digit(io, milliseconds)
      else
        seconds = DateTime.truncate_to_int(moment.seconds)
        digit(io, seconds.tdiv(10))
        digit(io, seconds)
      end
    end

    # printf's %0Nd (*zero* true) or %Nd of *value*.
    private def self.padded(io : IO, value : Int32, width : Int32, zero : Bool = true) : Nil
      digits = value.to_i64.abs.to_s
      fill = width - digits.bytesize - (value < 0 ? 1 : 0)
      fill.times { io << ' ' } unless zero
      io << '-' if value < 0
      fill.times { io << '0' } if zero
      io << digits
    end

    # printf's %06.3f of *seconds*.
    private def self.padded_seconds(io : IO, seconds : Float64) : Nil
      text = NumericText.format_float(seconds, NumericText::FloatFormat::Fixed, 3, alternate_form_2: false)
      (6 - text.bytesize).times { io << '0' }
      io << text
    end

    # strftime(FORMAT, TIMESTRING, MOD, ...): NULL for a conversion SQLite
    # does not know.
    def self.strftime(arguments : Array(Value), call : DateTime::Call) : Value
      return if arguments.empty?
      format = DateTime::Text.of(arguments[0]) || return
      moment = moment(arguments, call, 1) || return
      moment.compute_julian_day
      moment.compute_date_and_time
      pattern = format.to_slice
      io = IO::Memory.new(pattern.size + 16)
      copied = 0
      index = 0
      while index < pattern.size
        unless pattern.unsafe_fetch(index) == '%'.ord
          index += 1
          next
        end
        io.write(pattern[copied, index - copied]) if copied < index
        index += 1
        copied = index + 1
        conversion = index < pattern.size ? pattern.unsafe_fetch(index).unsafe_chr : '\0'
        return unless write_conversion(io, conversion, moment)
        index += 1
      end
      io.write(pattern[copied, pattern.size - copied]) if copied < pattern.size
      String.new(io.to_slice)
    end

    # One % conversion of strftime; false when SQLite has no such
    # conversion.
    private def self.write_conversion(io : IO, conversion : Char, moment : DateTime) : Bool
      case conversion
      when 'd' then padded(io, moment.day, 2)
      when 'e' then padded(io, moment.day, 2, zero: false)
      when 'f' then padded_seconds(io, Math.min(moment.seconds, 59.999))
      when 'F'
        padded(io, moment.year, 4)
        io << '-'
        padded(io, moment.month, 2)
        io << '-'
        padded(io, moment.day, 2)
      when 'G' then padded(io, moment.thursday_of_same_week.year, 4)
      when 'g' then padded(io, moment.thursday_of_same_week.year.remainder(100), 2)
      when 'H' then padded(io, moment.hour, 2)
      when 'k' then padded(io, moment.hour, 2, zero: false)
      when 'I' then padded(io, twelve_hour(moment.hour), 2)
      when 'l' then padded(io, twelve_hour(moment.hour), 2, zero: false)
      when 'j' then padded(io, moment.days_after_january_first + 1, 3)
      when 'J'
        io << NumericText.format_float(moment.julian_day_milliseconds / 86400000.0, NumericText::FloatFormat::Generic, 16, alternate_form_2: false)
      when 'm' then padded(io, moment.month, 2)
      when 'M' then padded(io, moment.minute, 2)
      when 'p' then io << (moment.hour >= 12 ? "PM" : "AM")
      when 'P' then io << (moment.hour >= 12 ? "pm" : "am")
      when 'R'
        padded(io, moment.hour, 2)
        io << ':'
        padded(io, moment.minute, 2)
      when 's'
        if moment.shows_subseconds?
          seconds = (moment.julian_day_milliseconds - DateTime::UNIX_EPOCH_JULIAN_DAY_MILLISECONDS) / 1000.0
          io << NumericText.format_float(seconds, NumericText::FloatFormat::Fixed, 3, alternate_form_2: false)
        else
          io << moment.julian_day_milliseconds.tdiv(1000) - 210_866_760_000_i64
        end
      when 'S' then padded(io, DateTime.truncate_to_int(moment.seconds), 2)
      when 'T'
        padded(io, moment.hour, 2)
        io << ':'
        padded(io, moment.minute, 2)
        io << ':'
        padded(io, DateTime.truncate_to_int(moment.seconds), 2)
      when 'u', 'w'
        weekday = moment.days_after_sunday
        weekday = 7 if weekday == 0 && conversion == 'u'
        io << ('0' + weekday)
      when 'U' then padded(io, (moment.days_after_january_first - moment.days_after_sunday + 7).tdiv(7), 2)
      when 'V' then padded(io, moment.thursday_of_same_week.days_after_january_first.tdiv(7) + 1, 2)
      when 'W' then padded(io, (moment.days_after_january_first - moment.days_after_monday + 7).tdiv(7), 2)
      when 'Y' then padded(io, moment.year, 4)
      when '%' then io << '%'
      else          return false
      end
      true
    end

    private def self.twelve_hour(hour : Int32) : Int32
      hour -= 12 if hour > 12
      hour == 0 ? 12 : hour
    end

    # timediff(A, B): the `±YYYY-MM-DD HH:MM:SS.SSS` that, added to B as a
    # modifier, gives A.
    def self.timediff(arguments : Array(Value), call : DateTime::Call) : Value
      later = moment(arguments, call, 0, 1) || return
      earlier = moment(arguments, call, 1, 1) || return
      later.compute_date_and_time
      earlier.compute_date_and_time
      forward = later.julian_day_milliseconds >= earlier.julian_day_milliseconds
      direction = forward ? 1 : -1
      years = (later.year - earlier.year) * direction
      if years != 0
        earlier.year = later.year
        earlier.has_valid_julian_day = false
        earlier.compute_julian_day
      end
      months = (later.month - earlier.month) * direction
      if months < 0
        years -= 1
        months += 12
      end
      if months != 0
        earlier.month = later.month
        earlier.has_valid_julian_day = false
        earlier.compute_julian_day
      end
      # Step the second date a month at a time until it no longer passes
      # the first.
      while forward ? later.julian_day_milliseconds < earlier.julian_day_milliseconds : later.julian_day_milliseconds > earlier.julian_day_milliseconds
        months -= 1
        if months < 0
          months = 11
          years -= 1
        end
        earlier.month -= direction
        if earlier.month < 1
          earlier.month = 12
          earlier.year -= 1
        elsif earlier.month > 12
          earlier.month = 1
          earlier.year += 1
        end
        earlier.has_valid_julian_day = false
        earlier.compute_julian_day
      end
      difference = (later.julian_day_milliseconds &- earlier.julian_day_milliseconds) * direction
      # The difference as a time of day and day count from julian day
      # 1721059.5, the start of year 0.
      later.julian_day_milliseconds = difference &+ 148_699_540_800_000_i64
      later.forget_calendar_fields
      later.compute_date_and_time
      String.build(25) do |io|
        io << (forward ? '+' : '-')
        padded(io, years, 4)
        io << '-'
        padded(io, months, 2)
        io << '-'
        padded(io, later.day - 1, 2)
        io << ' '
        padded(io, later.hour, 2)
        io << ':'
        padded(io, later.minute, 2)
        io << ':'
        padded_seconds(io, later.seconds)
      end
    end
  end
end
