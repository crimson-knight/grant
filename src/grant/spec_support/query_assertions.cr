require "spec"
require "../../grant"

# Spec helpers for Grant. Require them from a spec file or `spec_helper.cr`:
#
# ```
# require "grant/spec_support/*"
# ```
module Grant::Spec
  # Runs *block* and returns the SQL statements it issued.
  #
  # Only statements from the calling fiber, and from `Async::Result` fibers it
  # started, are recorded, so specs running side by side never see each
  # other's queries. Nothing is recorded outside the block.
  def self.capture_queries(& : ->) : Array(Grant::Events::SQL)
    owner = Fiber.current
    queries = [] of Grant::Events::SQL
    mutex = Mutex.new
    handler = ->(event : Grant::Events::SQL) do
      fiber = Fiber.current
      if fiber.same?(owner) || fiber.grant_async_origin.try(&.same?(owner))
        mutex.synchronize { queries << event }
      end
      nil
    end

    Grant::Notifications.subscribed(Grant::Events::SQL, handler) { yield }
    queries
  end

  # Fails unless *block* issued exactly *expected* queries. The failure message
  # lists every captured statement. Returns the captured queries.
  #
  # ```
  # Grant::Spec.assert_queries_count(2) { User.find!(1).posts.to_a }
  # ```
  def self.assert_queries_count(expected : Int32, file : String = __FILE__, line : Int32 = __LINE__, & : ->) : Array(Grant::Events::SQL)
    queries = capture_queries { yield }
    unless queries.size == expected
      fail_with("Expected #{expected} #{plural(expected)}, but #{queries.size} #{queries.size == 1 ? "was" : "were"} executed.", queries, file, line)
    end
    queries
  end

  # Fails if *block* issued any query.
  def self.assert_no_queries(file : String = __FILE__, line : Int32 = __LINE__, & : ->) : Array(Grant::Events::SQL)
    assert_queries_count(0, file, line) { yield }
  end

  # Fails unless a statement matching *pattern* ran. With *count*, exactly that
  # many statements must match. A `String` pattern matches as a substring.
  #
  # ```
  # Grant::Spec.assert_queries_match(/SELECT .* FROM "users"/, count: 1) { User.first }
  # ```
  def self.assert_queries_match(pattern : Regex | String, count : Int32? = nil, file : String = __FILE__, line : Int32 = __LINE__, & : ->) : Array(Grant::Events::SQL)
    queries = capture_queries { yield }
    matched = queries.count { |query| matches?(query.sql, pattern) }
    if expected = count
      unless matched == expected
        fail_with("Expected #{expected} #{plural(expected)} matching #{pattern.inspect}, but #{matched} matched.", queries, file, line)
      end
    elsif matched == 0
      fail_with("Expected a query matching #{pattern.inspect}, but none matched.", queries, file, line)
    end
    queries
  end

  # Fails if a statement matching *pattern* ran.
  def self.assert_no_queries_match(pattern : Regex | String, file : String = __FILE__, line : Int32 = __LINE__, & : ->) : Array(Grant::Events::SQL)
    queries = capture_queries { yield }
    if queries.any? { |query| matches?(query.sql, pattern) }
      fail_with("Expected no query matching #{pattern.inspect}, but one ran.", queries, file, line)
    end
    queries
  end

  private def self.matches?(sql : String, pattern : Regex | String) : Bool
    pattern.is_a?(Regex) ? !pattern.match(sql).nil? : sql.includes?(pattern)
  end

  private def self.plural(count : Int32) : String
    count == 1 ? "query" : "queries"
  end

  private def self.fail_with(headline : String, queries : Array(Grant::Events::SQL), file : String, line : Int32) : NoReturn
    message = String.build do |io|
      io << headline
      if queries.empty?
        io << "\nNo queries were captured."
      else
        io << "\nCaptured queries:"
        queries.each_with_index(1) do |query, index|
          io << "\n  " << index << ". " << query.sql
          io << " " << query.binds.inspect unless query.binds.empty?
        end
      end
    end
    raise ::Spec::AssertionFailed.new(message, file, line)
  end
end
