# Verbose SQL logging: a labeled line with the calling source location under
# each statement (ActiveRecord's `verbose_query_logs`), and a marker for reads
# answered by the query cache.
#
# ```
# Grant::Logs.verbose_query_logs = true
# # users Load (0.4ms)  ↳ src/app/users_controller.cr:12:5 in 'index'
# ```
#
# Finding the caller means capturing a backtrace for every statement, which is
# far costlier than the query itself on a hot path. So the location is only
# captured in a build without `-Drelease`, and only while the `grant.sql`
# source logs at debug level or below; otherwise the setting costs one flag
# read per statement.
module Grant::Logs
  @@verbose_query_logs = false

  # Whether each logged statement is followed by its label and source
  # location. Off by default; turn it on in development.
  def self.verbose_query_logs? : Bool
    @@verbose_query_logs
  end

  def self.verbose_query_logs=(value : Bool)
    @@verbose_query_logs = value
  end

  GRANT_SOURCE_ROOT = File.expand_path("..", __DIR__)
  STDLIB_FRAME      = %r{/(?:share/[\w.-]*crystal[\w.-]*|crystal)/src/}
  FRAME_LOCATION    = /\A(.+?:\d+(?::\d+)?)(.*)\z/m
  TABLE_AFTER       = /\b(?:FROM|INTO|UPDATE)\s+(?:ONLY\s+)?[`"\[]?([\w.$]+)/i

  # Writes the verbose lines for one executed statement. Called by
  # `Adapter::Base#log` after the statement's own entry.
  # *name* (usually the model) replaces the table in the label when known.
  def self.log_verbose(sql : String, elapsed_time : Time::Span, name : String? = nil) : Nil
    return unless @@verbose_query_logs
    {% unless flag?(:release) %}
      return unless SQL.level <= ::Log::Severity::Debug

      name ||= model_name_in(sql)
      location = source_location(caller)
      SQL.debug { "#{query_label(sql, name)} (#{format_milliseconds(elapsed_time)}ms)#{location ? "  ↳ #{location}" : ""}" }
    {% end %}
  end

  # Runs a hand-written statement (raw `Model.exec`, `Grant.connection`) and
  # writes its log entries afterwards, also when it raised. While the SQL source
  # is below the debug level the statement is not even timed.
  def self.timed(adapter : Grant::Adapter::Base, sql : String, binds, & : -> T) : T forall T
    return yield unless SQL.level <= ::Log::Severity::Debug

    started = Time.instant
    begin
      yield
    ensure
      adapter.log(sql, Time.instant - started, binds)
    end
  end

  # The name of the model whose table *sql* targets, or `nil` when no model
  # owns that table. Only used to label verbose lines, never on the hot path.
  private def self.model_name_in(sql : String) : String?
    table = TABLE_AFTER.match(sql).try(&.[1])
    table ? model_name_for_table(table) : nil
  end

  # The name of the model class that owns *table* (the first one declared when
  # several, such as single-table-inheritance models, share it), or `nil`.
  def self.model_name_for_table(table : String) : String?
    names = (@@model_names ||= __build_model_names)
    names[table]?
  end

  @@model_names : Hash(String, String)?

  # Writes the marker for a read served from the query cache.
  def self.log_cached_query(sql : String, name : String? = nil) : Nil
    return unless @@verbose_query_logs
    SQL.debug { "CACHE #{query_label(sql, name)} (0.0ms)" }
  end

  # The first backtrace frame that belongs to the application: not Grant, not
  # the Crystal standard library and not another shard under `lib/`.
  def self.source_location(frames : Array(String)) : String?
    frames.each do |frame|
      next unless match = FRAME_LOCATION.match(frame)
      path = frame.split(':', 2).first
      absolute = File.expand_path(path)
      next if absolute.starts_with?(GRANT_SOURCE_ROOT)
      next if STDLIB_FRAME.matches?(absolute) || absolute.includes?("/lib/")
      next if path == "??" || File.extname(path) != ".cr"

      return "#{match[1]}#{match[2]}"
    end
    nil
  end

  # A short name for a statement, from its kind and the model *name* (or the
  # table when no name is known): `User Load`, `users Create`, `users Update`,
  # `users Destroy`, `users Exists?`; `SQL` when the kind is not recognized.
  def self.query_label(sql : String, name : String? = nil) : String
    verb = sql.lstrip[0, 12].upcase
    kind = if verb.starts_with?("SELECT")
             sql.lstrip.upcase.starts_with?("SELECT EXISTS") ? "Exists?" : "Load"
           elsif verb.starts_with?("INSERT")
             "Create"
           elsif verb.starts_with?("UPDATE")
             "Update"
           elsif verb.starts_with?("DELETE")
             "Destroy"
           end
    return "SQL" unless kind

    table = name || TABLE_AFTER.match(sql).try(&.[1])
    table ? "#{table} #{kind}" : kind
  end

  private def self.format_milliseconds(elapsed_time : Time::Span) : String
    (elapsed_time.total_milliseconds.round(1)).to_s
  end
end

macro finished
  # The table-to-model map behind `Grant::Logs.model_name_for_table`, built from
  # every concrete model compiled into the program.
  # :nodoc:
  def Grant::Logs.__build_model_names : Hash(String, String)
    names = {} of String => String
    {% for klass in Grant::Base.all_subclasses %}
      {% unless klass.abstract? || !klass.type_vars.empty? || klass.name.starts_with?("Validators::") || klass.name.starts_with?("Spec::") %}
        names[{{klass}}.table_name] ||= {{klass.name.stringify}}
      {% end %}
    {% end %}
    names
  end
end
