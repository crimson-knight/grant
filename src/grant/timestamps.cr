require "./settings"

# Automatic timestamps, the per-model `record_timestamps` switch, and the
# block-scoped `no_touching` / `suppress` helpers.
#
# ```
# class Post < Grant::Base
#   column id : Int64, primary: true
#   column title : String
#   timestamps
#
#   record_timestamps false # opt this model out of automatic stamping
# end
#
# Post.no_touching { post.touch }    # touch becomes a no-op inside the block
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

  # Tracks, per fiber, how many blocks are open for each model name. A `spawn`ed
  # fiber starts with nothing suppressed, so a scope never leaks across fibers.
  class FiberScope
    def initialize
      @mutex = Mutex.new
      @scopes = {} of Fiber => Hash(String, Int32)
    end

    # Runs the block with *name* active on the current fiber.
    def within(name : String, & : -> T) : T forall T
      fiber = Fiber.current
      @mutex.synchronize do
        counts = (@scopes[fiber] ||= {} of String => Int32)
        counts[name] = (counts[name]? || 0) + 1
      end
      begin
        yield
      ensure
        @mutex.synchronize do
          if counts = @scopes[fiber]?
            remaining = (counts[name]? || 1) - 1
            if remaining > 0
              counts[name] = remaining
            else
              counts.delete(name)
              @scopes.delete(fiber) if counts.empty?
            end
          end
        end
      end
    end

    # True when the current fiber has a block open for any of *lineage*.
    def active?(lineage : Array(String)) : Bool
      counts = @mutex.synchronize { @scopes[Fiber.current]? }
      return false unless counts
      lineage.any? { |name| counts.has_key?(name) }
    end
  end

  NO_TOUCHING = FiberScope.new
  SUPPRESSED  = FiberScope.new

  module ClassMethods
    # True unless the model declared `record_timestamps false`.
    def record_timestamps? : Bool
      true
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
      Grant::Timestamps::NO_TOUCHING.within(name) { yield }
    end

    # True while a `no_touching` block for this model (or a superclass) is open
    # on the current fiber.
    def no_touching? : Bool
      Grant::Timestamps::NO_TOUCHING.active?(__lineage_names)
    end

    # Runs the block with `save` (and so `create`, `update`) turned into a
    # successful no-op for this model and its subclasses on the current fiber.
    #
    # ```
    # Notification.suppress { Notification.create!(user_id: 1) } # writes nothing
    # ```
    def suppress(& : -> T) : T forall T
      Grant::Timestamps::SUPPRESSED.within(name) { yield }
    end

    # True while a `suppress` block for this model (or a superclass) is open on
    # the current fiber.
    def suppressed? : Bool
      Grant::Timestamps::SUPPRESSED.active?(__lineage_names)
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
    def self.record_timestamps? : Bool
      {{ value }}
    end
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
    {% for ivar in @type.instance_vars %}
      {% if ivar.annotation(Grant::Column) && ivar.type == Time? %}
        {% if ["created_at", "created_on"].includes?(ivar.name.stringify) %}
          @{{ ivar.name.id }} = time if mode == :create
        {% elsif ["updated_at", "updated_on"].includes?(ivar.name.stringify) %}
          @{{ ivar.name.id }} = time
        {% end %}
      {% end %}
    {% end %}
  end

  # True while `touch` is disabled for this record's class on the current fiber.
  def no_touching? : Bool
    self.class.no_touching?
  end
end
