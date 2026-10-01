require "uri"

# Query log tags: a trailing SQL comment carrying the application, request,
# controller, job or any other context that issued a statement, so a slow
# query in `pg_stat_activity`, the MySQL slow log or an APM trace leads back to
# the code path behind it (ActiveRecord's `ActiveRecord::QueryLogs`).
#
# ```
# Grant::QueryLogs.enabled = true
# Grant::QueryLogs.format = Grant::QueryLogs::Format::SQLCommenter
# Grant::QueryLogs.tag(:application, "shop")
# Grant::QueryLogs.tag(:request_id) { Current.request_id }
#
# Grant::QueryLogs.with_context(controller: "users", action: "index") do
#   User.where(active: true).to_a
#   # SELECT ... FROM "users" WHERE active = $1 /*action='index',application='shop',controller='users'*/
# end
# ```
#
# Configure the tags once at boot. The context is per fiber: a fiber spawned
# inside `with_context` does not inherit it, so wrap its body in its own call.
#
# The comment is appended after the SQL, never prepended, so servers that key
# prepared statements or statistics on the statement prefix keep grouping
# identical queries. A tag whose value changes on every request (a request id)
# still makes each statement text unique, which defeats a client-side
# prepared-statement cache and `pg_stat_statements` grouping on servers that
# hash the comment; keep such tags out if that matters more than tracing.
#
# Covered: every statement Grant sends, whichever path built it: relation
# statements (finders, aggregations, `pluck`, `update_all`, `delete_all`, ...),
# the adapters' record `insert`, `update`, `delete`, `select` and `exists?`,
# counter updates, `insert_all`/`upsert_all`, raw `Model.exec`/`query`/`scalar`
# and the `Grant.connection` helpers. The only statements sent as given are
# those a block writes on the raw `DB::Connection` that `with_connection`
# yields; call `QueryLogs.append` on their SQL to tag them. Request and job
# context comes from the application through `with_context` (Grant does not
# depend on a web framework).
module Grant::QueryLogs
  # How the tags are written inside the comment.
  enum Format
    # `/*application:shop,controller:users*/`, in tag order.
    Legacy
    # sqlcommenter (Google Cloud SQL Insights, OpenTelemetry):
    # `/*action='index',controller='users'*/`. Keys are sorted and values are
    # URL-encoded and single-quoted.
    SQLCommenter
  end

  # One configured tag: a fixed value, or a block evaluated for every
  # statement. A block that returns `nil` leaves its tag out.
  struct Tag
    getter name : String
    @value : String?
    @source : Proc(String?)?

    def initialize(@name : String, @value : String? = nil, @source : Proc(String?)? = nil)
    end

    def resolve : String?
      @source.try(&.call) || @value
    end
  end

  @@enabled = false
  @@format = Format::Legacy
  @@tags = [] of Tag

  # Whether statements get a comment. Off by default.
  def self.enabled? : Bool
    @@enabled
  end

  def self.enabled=(value : Bool)
    @@enabled = value
  end

  def self.format : Format
    @@format
  end

  def self.format=(value : Format)
    @@format = value
  end

  # The configured tags, in the order they are written.
  def self.tags : Array(Tag)
    @@tags
  end

  # Adds a tag with a fixed *value*. Replaces an earlier tag of the same name.
  def self.tag(name : Symbol | String, value : String) : Nil
    replace_tag(Tag.new(name.to_s, value: value))
  end

  # Adds a tag whose value the block returns for every statement; return
  # `nil` to skip the tag for that statement. Keep the block cheap: it runs
  # once per query.
  def self.tag(name : Symbol | String, &source : -> String?) : Nil
    replace_tag(Tag.new(name.to_s, source: source))
  end

  # Removes every configured tag (the fiber context is left alone).
  def self.clear_tags : Nil
    @@tags = [] of Tag
  end

  # Back to the defaults: disabled, legacy format, no tags.
  def self.reset! : Nil
    @@enabled = false
    @@format = Format::Legacy
    @@tags = [] of Tag
  end

  # Runs the block with *values* added to the current fiber's context, merged
  # over any enclosing `with_context`, and restores the previous context after
  # it, also when it raises.
  #
  # ```
  # Grant::QueryLogs.with_context(job: "SendDigest", queue: "mail") { ... }
  # ```
  def self.with_context(**values, & : -> T) : T forall T
    previous = Fiber.current.grant_query_log_context
    merged = previous ? previous.dup : {} of String => String
    values.each { |key, value| merged[key.to_s] = value.to_s }
    Fiber.current.grant_query_log_context = merged
    begin
      yield
    ensure
      Fiber.current.grant_query_log_context = previous
    end
  end

  # The current fiber's context values (empty outside `with_context`).
  def self.context : Hash(String, String)
    Fiber.current.grant_query_log_context || ({} of String => String)
  end

  # The comment for a statement issued now, or `nil` when tagging is off or
  # no tag has a value.
  def self.comment : String?
    return nil unless @@enabled

    pairs = collect_pairs
    return nil if pairs.empty?

    body = case @@format
           in .legacy?
             pairs.map { |key, value| "#{escape(key)}:#{escape(value)}" }.join(',')
           in .sql_commenter?
             pairs.sort_by { |key, _| key }.map { |key, value| "#{encode(key)}='#{encode(value)}'" }.join(',')
           end
    # A body ending in "/" would fuse with the closing "*/" into a nested "/*".
    body += " " if body.ends_with?('/')
    "/*#{body}*/"
  end

  # Returns *sql* with the tag comment appended; *sql* itself when tagging is
  # off, nothing has a value, or the comment is already there (a statement
  # built by a relation passes through the adapter as well).
  def self.append(sql : String) : String
    return sql unless @@enabled
    return sql unless comment = self.comment
    return sql if sql.ends_with?(comment)

    "#{sql} #{comment}"
  end

  # Neutralizes comment delimiters so a value cannot end the comment early, or
  # open one that MySQL would execute (`/*! ... */`).
  def self.escape(text : String) : String
    text.gsub("*/", "* /").gsub("/*", "/ *").delete('\0')
  end

  private def self.encode(text : String) : String
    escape(URI.encode_www_form(text, space_to_plus: false))
  end

  private def self.replace_tag(tag : Tag) : Nil
    @@tags = @@tags.reject { |existing| existing.name == tag.name } + [tag]
  end

  private def self.collect_pairs : Array({String, String})
    pairs = [] of {String, String}
    @@tags.each do |tag|
      if value = tag.resolve
        pairs << {tag.name, value}
      end
    end
    if values = Fiber.current.grant_query_log_context
      values.each do |key, value|
        next if pairs.any? { |pair| pair[0] == key }
        pairs << {key, value}
      end
    end
    pairs
  end
end

class Fiber
  # Fiber-local slot for `Grant::QueryLogs.with_context`.
  # :nodoc:
  property grant_query_log_context : Hash(String, String)?
end
