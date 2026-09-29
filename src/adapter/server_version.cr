# A database server version, compared numerically so `9.6 < 10.0 < 10.10`.
#
# Adapters use it to gate capability predicates that depend on the server's
# release, for example `Grant::Adapter::Base#supports_json?`.
struct Grant::ServerVersion
  include Comparable(Grant::ServerVersion)

  getter major : Int32
  getter minor : Int32
  getter patch : Int32

  def initialize(@major : Int32, @minor : Int32 = 0, @patch : Int32 = 0)
  end

  # Reads the leading `major[.minor[.patch]]` digits of a server banner such as
  # `"8.0.35"`, `"10.6.12-MariaDB-log"` or `"3.45.1"`. Missing parts are zero.
  def self.parse(text : String) : Grant::ServerVersion
    parts = [] of Int32
    text.split('.', 4) do |part|
      digits = part.each_char.take_while(&.ascii_number?).join
      break if digits.empty?
      parts << digits.to_i
      break if digits.size != part.size
    end

    raise ArgumentError.new("Unrecognized server version: #{text.inspect}") if parts.empty?
    new(parts[0], parts[1]? || 0, parts[2]? || 0)
  end

  def <=>(other : Grant::ServerVersion) : Int32
    result = major <=> other.major
    result = minor <=> other.minor if result == 0
    result = patch <=> other.patch if result == 0
    result
  end

  # True when this version is at least *major*.*minor*.*patch*.
  def at_least?(major : Int32, minor : Int32 = 0, patch : Int32 = 0) : Bool
    self >= Grant::ServerVersion.new(major, minor, patch)
  end

  def to_s(io : IO) : Nil
    io << major << '.' << minor << '.' << patch
  end
end
