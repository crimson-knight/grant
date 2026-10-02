require "./settings"

# Automatic timestamps, the per-model `record_timestamps` switch, and the
# block-scoped `no_touching` / `suppress` helpers.
#
# `created_on` / `updated_on` columns are date columns: Crystal has no `Date`
# type, so they are `Time` values stamped at midnight UTC of the current date in
# the default timezone (`date_timestamps` declares them with a `DATE` type).
# `timestamps precision: 3` truncates every stamped value to milliseconds.
#
# ```
# class Post < Grant::Base
#   column id : Int64, primary: true
#   column title : String
#   timestamps precision: 3
#
#   record_timestamps false # opt this model out of automatic stamping
# end
#
# Post.record_timestamps = true # switch it back on at run time
#
# Post.no_touching { post.touch }     # touch becomes a no-op inside the block
# Post.suppress { Post.create!(...) } # save becomes a no-op inside the block
# ```
module Grant::Timestamps
  CREATED_COLUMNS = {"created_at", "created_on"}
  UPDATED_COLUMNS = {"updated_at", "updated_on"}

  # The one clock every stamping path reads: the current time in the
  # configured default timezone.
  def self.current_time : Time
    Time.local(Grant.settings.default_timezone)
  end

  @@overrides = {} of String => Bool

  # Run-time `Model.record_timestamps = value` settings by model name. The hash
  # is replaced, never mutated, so readers take no lock.
  #
  # :nodoc:
  def self.overrides : Hash(String, Bool)
    @@overrides
  end

  # :nodoc:
  def self.override(model_name : String, value : Bool) : Nil
    updated = @@overrides.dup
    updated[model_name] = value
    @@overrides = updated
  end

  # The value to store in the timestamp column *column_name* for the instant
  # *time*: the date at midnight UTC for `*_on` columns, otherwise *time*
  # truncated to *precision* fractional digits (all digits when nil).
  def self.stamp(column_name : String, time : Time, precision : Int32? = nil) : Time
    if column_name.ends_with?("_on")
      local = time.in(Grant.settings.default_timezone)
      Time.utc(local.year, local.month, local.day)
    elsif precision
      truncate(time, precision)
    else
      time
    end
  end

  # *time* without the fractional digits beyond *precision* (0 to 9).
  def self.truncate(time : Time, precision : Int32) : Time
    return time if precision >= 9
    unit = 10 ** (9 - precision.clamp(0, 9))
    time - (time.nanosecond % unit).nanoseconds
  end

  # Counts of the `no_touching` / `suppress` blocks open on one fiber, keyed by
  # model name. It lives in a fiber-local slot, so a `spawn`ed fiber starts with
  # nothing suppressed, a scope never leaks across fibers, and checking it takes
  # no lock.
  #
  # :nodoc:
  class BlockScopes
    getter no_touching = {} of String => Int32
    getter suppressed = {} of String => Int32
  end

  # The current fiber's block counts, created on first use.
  #
  # :nodoc:
  def self.block_scopes : BlockScopes
    fiber = Fiber.current
    fiber.grant_block_scopes || (fiber.grant_block_scopes = BlockScopes.new)
  end

  # Runs the block with *name* counted as open in *counts*, unwinding the count
  # even when the block raises.
  #
  # :nodoc:
  def self.within(counts : Hash(String, Int32), name : String, & : -> T) : T forall T
    counts[name] = (counts[name]? || 0) + 1
    begin
      yield
    ensure
      remaining = (counts[name]? || 1) - 1
      if remaining > 0
        counts[name] = remaining
      else
        counts.delete(name)
      end
    end
  end

  module ClassMethods
    # Whether saves stamp the timestamp columns: the run-time
    # `record_timestamps =` setting, else the `record_timestamps` declaration,
    # else true.
    def record_timestamps? : Bool
      overrides = Grant::Timestamps.overrides
      unless overrides.empty?
        __lineage_names.each do |model_name|
          if found = overrides[model_name]?
            return found
          elsif overrides.has_key?(model_name)
            return false
          end
        end
      end
      __record_timestamps_default
    end

    # Turns stamping on or off for this model and its subclasses at run time
    # (ActiveRecord's `record_timestamps=`). Takes effect for every fiber.
    def record_timestamps=(value : Bool) : Bool
      Grant::Timestamps.override(name, value)
      value
    end

    # :nodoc:
    def __record_timestamps_default : Bool
      true
    end

    # Fractional digits kept in stamped values; nil keeps them all.
    def timestamp_precision : Int32?
      nil
    end

    # The timestamp columns this model declares (`created_at`, `updated_at`,
    # `created_on`, `updated_on`), in declaration order.
    def timestamped_attributes : Array(String)
      {% begin %}
        {% names = @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.type == Time? && ["created_at", "created_on", "updated_at", "updated_on"].includes?(ivar.name.stringify) }.map(&.name.stringify) %}
        {{names.empty? ? "[] of String".id : names}}
      {% end %}
    end

    # The columns a touch or a counter update refreshes: `updated_at` /
    # `updated_on` when the model declares them.
    def update_timestamp_columns : Array(String)
      timestamped_attributes.select { |column_name| Grant::Timestamps::UPDATED_COLUMNS.includes?(column_name) }
    end

    # Runs the block with `touch` disabled for this model and its subclasses on
    # the current fiber. Saves still stamp `updated_at`; only `touch` (and touch
    # cascades built on it) is skipped.
    #
    # ```
    # User.no_touching { user.touch } # returns true, writes nothing
    # ```
    def no_touching(& : -> T) : T forall T
      Grant::Timestamps.within(Grant::Timestamps.block_scopes.no_touching, name) { yield }
    end

    # True while a `no_touching` block for this model (or a superclass) is open
    # on the current fiber.
    def no_touching? : Bool
      # Every save and touch asks, so the common case (no block open on this
      # fiber) returns before building the class lineage.
      scopes = Fiber.current.grant_block_scopes
      return false unless scopes
      counts = scopes.no_touching
      return false if counts.empty?
      __lineage_names.any? { |model_name| counts.has_key?(model_name) }
    end

    # Runs the block with `save` (and so `create`, `update`) turned into a
    # successful no-op for this model and its subclasses on the current fiber.
    #
    # ```
    # Notification.suppress { Notification.create!(user_id: 1) } # writes nothing
    # ```
    def suppress(& : -> T) : T forall T
      Grant::Timestamps.within(Grant::Timestamps.block_scopes.suppressed, name) { yield }
    end

    # True while a `suppress` block for this model (or a superclass) is open on
    # the current fiber.
    def suppressed? : Bool
      scopes = Fiber.current.grant_block_scopes
      return false unless scopes
      counts = scopes.suppressed
      return false if counts.empty?
      __lineage_names.any? { |model_name| counts.has_key?(model_name) }
    end
  end

  # Turns automatic timestamp stamping on or off for the model. Defaults to on.
  #
  # ```
  # class AuditRow < Grant::Base
  #   timestamps
  #   record_timestamps false
  # end
  # ```
  macro record_timestamps(value)
    def self.__record_timestamps_default : Bool
      {{ value }}
    end
  end

  # Declares the date-granular `created_on` and `updated_on` columns (`DATE` in
  # the database, `Time` at midnight UTC in Crystal).
  #
  # ```
  # class Invoice < Grant::Base
  #   date_timestamps
  # end
  # ```
  macro date_timestamps
    column created_on : Time?, column_type: "DATE"
    column updated_on : Time?, column_type: "DATE"
  end

  # Sets the record's creation and/or update timestamps to *time* (default:
  # now in the configured default timezone). Handles `created_at`/`updated_at`
  # and the `created_on`/`updated_on` spellings; columns the model doesn't
  # declare are skipped.
  #
  # This is a low-level helper invoked automatically by `#save`; you rarely call
  # it directly. With `mode: :create` both are set; with `mode: :update` only
  # the update column is. Sub-second precision is preserved.
  #
  # ```
  # user.set_timestamps                           # create mode: sets both
  # user.set_timestamps(mode: :update)            # only updated_at
  # user.set_timestamps(to: Time.utc(2020, 1, 1)) # pin a specific time
  # ```
  def set_timestamps(*, to time = Grant::Timestamps.current_time, mode = :create)
    precision = self.class.timestamp_precision
    {% for ivar in @type.instance_vars %}
      {% if ivar.annotation(Grant::Column) && ivar.type == Time? %}
        {% if ["created_at", "created_on"].includes?(ivar.name.stringify) %}
          @{{ ivar.name.id }} = Grant::Timestamps.stamp({{ ivar.name.stringify }}, time, precision) if mode == :create
        {% elsif ["updated_at", "updated_on"].includes?(ivar.name.stringify) %}
          @{{ ivar.name.id }} = Grant::Timestamps.stamp({{ ivar.name.stringify }}, time, precision)
        {% end %}
      {% end %}
    {% end %}
  end

  # True while `touch` is disabled for this record's class on the current fiber.
  def no_touching? : Bool
    self.class.no_touching?
  end
end

class Fiber
  # Fiber-local slot for `Grant::Timestamps::BlockScopes`.
  # :nodoc:
  property grant_block_scopes : Grant::Timestamps::BlockScopes?
end
