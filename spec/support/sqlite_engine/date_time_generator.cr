require "./query_oracle"

# Seeded random calls of SQLite's date and time functions, for comparing
# Grant's engine with C SQLite: time values in every format of
# lang_datefunc.html (and broken ones), chains of zero to four modifiers,
# and every strftime conversion.
class SQLiteDateTimeGenerator
  alias Value = Grant::SQLiteEngine::Value

  FUNCTIONS   = %w[date time datetime julianday unixepoch]
  CONVERSIONS = %w[d e f F G g H I j J k l m M p P R s S T u U V w W Y %]
  UNITS       = %w[second minute hour day month year]
  WORDS       = ["ceiling", "floor", "start of month", "start of year", "start of day", "unixepoch", "julianday", "auto",
                 "localtime", "utc", "subsec", "subsecond"]
  BROKEN = ["", " ", "abc", "start of week", "start of", "+1", "days", "weekday", "weekday 7", "weekday -1", "weekday 2.5",
            "weekday 3.0", "weekday  1", "+ 1 day", "1 fortnight", "++1 day", "1e2 seconds", ".5 days", "5. hours",
            "+00:00", "-00:00:00.000", "+24:00", "+12:60", "12:30", "+1 12:30", "0 months", "-0 years", "+0000-00-00",
            "-0000-00-00 00:00", "+0001-12-00", "+0001-00-31", "+00001-00-00", "+14712-00-00", "+14713-00-00",
            "+0001-01-01 25:00", "+0001-01-01 10:00:00.5", "+0001-01-01T10:00", "+0001-01-01 10:00 ", "1-01-01", "now", "nowx"]
  FRAGMENTS = [" ", "-", ":", ".", "T", "Z", "+", "0", "9", "x", "%", "\t", "é"]

  def initialize(seed : Int32)
    @random = Random.new(seed.to_u64)
  end

  # One call: its SQL with `?N` parameters, and their values. The second
  # column shows the result as text, so REAL results compare as rendered
  # too.
  def call : {String, Array(Value)}
    parameters = [] of Value
    name, arguments = pick(8) == 0 ? timediff_call : function_call
    rendered = arguments.map do |argument|
      if pick(3) == 0 && !argument.is_a?(Bytes)
        literal(argument)
      else
        parameters << argument
        "?#{parameters.size}"
      end
    end
    call = "#{name}(#{rendered.join(", ")})"
    {"SELECT #{call}, CAST(#{call} AS TEXT), typeof(#{call})", parameters}
  end

  private def pick(count : Int32) : Int32
    @random.rand(count)
  end

  private def literal(value : Value) : String
    case value
    when Nil    then "NULL"
    when String then "'#{value.gsub("'", "''")}'"
    else             value.to_s
    end
  end

  private def timediff_call : {String, Array(Value)}
    first = time_value
    second = pick(3) == 0 ? near(first) : time_value
    {"timediff", [first, second]}
  end

  # A time value close to *value*, so differences of days and months are
  # exercised.
  private def near(value : Value) : Value
    return time_value unless value.is_a?(String) && value.size >= 10
    "#{value[0, 8]}#{two(1 + pick(31))} #{clock_text}"
  end

  private def function_call : {String, Array(Value)}
    arguments = [] of Value
    name = FUNCTIONS[pick(FUNCTIONS.size)]
    if pick(3) == 0
      name = "strftime"
      arguments << format
    end
    value = time_value
    arguments << value
    count = {0, 0, 1, 1, 1, 2, 2, 3, 4}[pick(9)]
    # A number is a unix time only under the modifier that says so.
    if (value.is_a?(Int64) || value.is_a?(Float64)) && pick(4) != 0
      arguments << {"unixepoch", "auto", "julianday", "auto"}[pick(4)]
      count -= 1 if count > 0
    end
    count.times { arguments << modifier }
    {name, arguments}
  end

  private def format : Value
    return nil if pick(200) == 0
    String.build do |io|
      (1 + pick(5)).times do
        io << {"", " ", "-", "T", "at ", "é", ":"}[pick(7)]
        case pick(150)
        when 0 then io << "%q"
        when 1 then io << "%"
        else        io << '%' << CONVERSIONS[pick(CONVERSIONS.size)]
        end
      end
      io << "%" if pick(60) == 0
    end
  end

  private def two(value : Int32) : String
    value.to_s.rjust(2, '0')
  end

  private def year : Int32
    case pick(12)
    when 0    then 0
    when 1    then 9999
    when 2    then pick(10000)
    when 3    then 1969 + pick(3)
    when 4    then 2037 + pick(3)
    when 5    then {1, 4, 100, 400, 1582, 1600, 1900, 2000, 2100, 9998}[pick(10)]
    when 6, 7 then 1900 + pick(200)
    else           2000 + pick(40)
    end
  end

  private def date_text : String
    month = pick(40) == 0 ? {0, 13, 19}[pick(3)] : 1 + pick(12)
    day = case pick(12)
          when 0 then {0, 29, 30, 31, 32}[pick(5)]
          when 1 then 28 + pick(4)
          else        1 + pick(28)
          end
    month = 2 if pick(10) == 0
    sign = pick(40) == 0 ? "-" : ""
    year_text = year.to_s.rjust(4, '0')
    year_text = {"4713", "4714", "0001", "0000"}[pick(4)] if sign == "-" && pick(2) == 0
    "#{sign}#{year_text}-#{two(month)}-#{two(day)}"
  end

  private def fraction : String
    digits = case pick(8)
             when 0 then 1 + pick(3)
             when 1 then 7 + pick(12)
             when 2 then 3
             else        6
             end
    return ".999999" if pick(25) == 0
    return ".#{"9" * digits}" if pick(25) == 0
    return ".#{"0" * digits}" if pick(25) == 0
    ".#{String.build { |io| digits.times { io << pick(10) } }}"
  end

  private def clock_text : String
    hour = pick(40) == 0 ? 24 + pick(2) : pick(24)
    minute = pick(60) == 0 ? 60 : pick(60)
    text = "#{two(hour)}:#{two(minute)}"
    return text if pick(8) == 0
    second = pick(60) == 0 ? 60 : pick(60)
    text = "#{text}:#{two(second)}"
    return text if pick(6) == 0
    "#{text}#{fraction}"
  end

  private def zone_text : String
    case pick(8)
    when 0 then "Z"
    when 1 then " z"
    when 2 then "+00:00"
    when 3 then "-00:00"
    when 4 then " +#{two(pick(16))}:#{two(pick(62))}"
    else        "#{pick(2) == 0 ? '+' : '-'}#{two(pick(15))}:#{{"00", "30", "45", two(pick(60))}[pick(4)]}"
    end
  end

  private def time_value : Value
    value = plain_time_value
    return mutate(value) if value.is_a?(String) && pick(25) == 0
    value
  end

  private def plain_time_value : Value
    case pick(30)
    when 0..9
      # Grant's stored format: six fractional digits.
      "#{date_text} #{two(pick(24))}:#{two(pick(60))}:#{two(pick(60))}.#{String.build { |io| 6.times { io << pick(10) } }}"
    when 10, 11 then date_text
    when 12..15
      separator = {" ", " ", "T", "  ", "TT", " T "}[pick(6)]
      text = "#{date_text}#{separator}#{clock_text}"
      text = "#{text}#{zone_text}" if pick(3) == 0
      text = "#{text} " if pick(20) == 0
      text
    when 16, 17
      text = clock_text
      text = "#{text}#{zone_text}" if pick(4) == 0
      text
    when 18 then pick(5373485).to_f64 + pick(1000) / 1000.0
    when 19 then (pick(5373485).to_f64 + pick(86400000) / 86400000.0).to_s
    when 20 then pick(5400000).to_i64 - 5000
    when 21 then @random.rand(-220_000_000_000_i64..260_000_000_000_i64)
    when 22 then @random.rand(-2_000_000_000_i64..5_000_000_000_i64)
    when 23 then @random.rand(-2_000_000_000_i64..5_000_000_000_i64) + pick(1000) / 1000.0
    when 24 then (@random.rand(-2_000_000_000_i64..5_000_000_000_i64) + pick(1000) / 1000.0).to_s
    when 25 then {5373484.5, 5373484.499999, 0.0, -0.5, 1e300, -1e300, 2440587.5, 1721059.5, 5373484.0}[pick(9)]
    when 26 then {"2460000.5", " 2460000.5", "2460000.5 ", "1e6", "0x10", "+2460000", "-1", "2460000.", ".5", "1700000000"}[pick(10)]
    when 27 then {nil, "", "abc", "nowhere", "2026", "2026-11", "2026-11-2", "20261124", "2026/11/24", "24:00:00", "1:00"}[pick(11)]
    when 28 then pick(2) == 0 ? "2026-11-24 10:11:12.123456".to_slice.dup : Bytes[0x32, 0x30, 0x00, 0x31]
    else         "#{date_text} #{clock_text}\0junk"
    end
  end

  private def mutate(text : String) : String
    return text if text.empty?
    position = pick(text.size)
    case pick(3)
    when 0 then text.sub(position, FRAGMENTS[pick(FRAGMENTS.size)])
    when 1 then "#{text[0, position]}#{text[position + 1..]}"
    else        "#{text[0, position]}#{FRAGMENTS[pick(FRAGMENTS.size)]}#{text[position..]}"
    end
  end

  private def sign : String
    {"+", "-", "", "+", "-"}[pick(5)]
  end

  private def amount : String
    case pick(12)
    when 0 then "#{pick(100)}.#{pick(1000)}"
    when 1 then "0.#{pick(100)}"
    when 2 then pick(1_000_000).to_s
    when 3 then {"14712", "14713", "176545", "176546", "5373484", "5373485", "128970000000", "7737900000000",
                 "464270000000000", "1e3", "1.5e1", "9999999999999999999", "0", "0.5", "0.999", "1e-3"}[pick(16)]
    when 4 then pick(13).to_s
    else        pick(40).to_s
    end
  end

  private def scramble_case(text : String) : String
    return text unless pick(8) == 0
    text.gsub { |character| pick(2) == 0 ? character.upcase : character }
  end

  private def modifier : Value
    value = plain_modifier
    return mutate(value) if value.is_a?(String) && pick(30) == 0
    value
  end

  private def plain_modifier : Value
    case pick(40)
    when 0..15
      unit = UNITS[pick(UNITS.size)]
      unit = UNITS[4 + pick(2)] if pick(4) == 0
      unit = "#{unit}s" if pick(2) == 0
      spaces = {" ", " ", " ", "", "  ", "\t"}[pick(6)]
      scramble_case("#{sign}#{amount}#{spaces}#{unit}")
    when 16..19
      text = "#{pick(2) == 0 ? '+' : '-'}#{pick(6) == 0 ? pick(15000).to_s.rjust(pick(2) == 0 ? 4 : 5, '0') : pick(30).to_s.rjust(4, '0')}"
      text = "#{text}-#{two(pick(40) == 0 ? 12 : pick(12))}-#{two(pick(40) == 0 ? 31 : pick(31))}"
      text = "#{text} #{clock_text}" if pick(2) == 0
      text = "#{text}#{zone_text}" if pick(30) == 0
      text
    when 20..23
      text = "#{sign}#{clock_text}"
      text = "#{text}#{zone_text}" if pick(20) == 0
      text
    when 24..33
      word = WORDS[pick(WORDS.size)]
      word = {"ceiling", "floor", "start of month", "start of year", "start of day", "localtime", "utc", "subsec"}[pick(8)] if pick(3) != 0
      scramble_case(word)
    when 34..36 then scramble_case("weekday #{pick(7)}")
    when 37     then BROKEN[pick(BROKEN.size)]
    when 38     then {nil, 5_i64, 1.5, 0_i64, "weekday 6 ".to_slice.dup}[pick(5)].as(Value)
    else             scramble_case("#{sign}#{amount} #{UNITS[pick(UNITS.size)]}s ")
    end
  end
end
