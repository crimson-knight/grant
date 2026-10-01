require "./exceptions"

# `Grant::DeleteRestrictionError` is ActiveRecord's name for the error raised by
# `dependent: :restrict_with_exception`.
alias Grant::DeleteRestrictionError = Grant::Associations::RestrictError

# Runtime support for the `dependent:` association option: the value check that
# runs while a model compiles, `destroyed_by_association`, and the asynchronous
# destroy queue behind `dependent: :destroy_async`.
#
# ```
# class Author < Grant::Base
#   has_many :posts, dependent: :destroy_async
# end
#
# # Hand jobs to your own queue instead of the default fiber:
# Grant::Dependent.async_destroy_enqueuer = ->(job : Grant::Dependent::AsyncDestroyJob) do
#   MyQueue.push(job.owner_class, job.association, job.key)
# end
# ```
module Grant::Dependent
  # One unit of `dependent: :destroy_async` work. The job holds only plain
  # values (no records), so it can travel through any queue. `#perform` finds
  # the dependents by key and destroys them, so running it again finds nothing
  # and does nothing.
  struct AsyncDestroyJob
    getter owner_class : String
    getter association : String
    getter key : Int64 | String

    def initialize(@owner_class : String, @association : String, @key : Int64 | String)
    end

    # Destroys the dependents and returns how many were destroyed. The
    # dependents are found with one query and destroyed in batches; the job does
    # nothing while the owner row still exists (a rolled-back destroy).
    def perform : Int64
      if destroyer = Grant::Dependent.destroyer_for(@owner_class, @association)
        destroyer.call(@key)
      else
        0_i64
      end
    end
  end

  alias Destroyer = Proc(Int64 | String, Int64)
  alias Enqueuer = Proc(AsyncDestroyJob, Nil)

  @@destroyers = {} of Tuple(String, String) => Destroyer
  @@mutex = Mutex.new
  @@enqueuer : Enqueuer = default_enqueuer

  # The callable that receives every `dependent: :destroy_async` job. The
  # default runs the job in a new fiber. Replace it with one that pushes the job
  # to a background job system.
  def self.async_destroy_enqueuer : Enqueuer
    @@mutex.synchronize { @@enqueuer }
  end

  def self.async_destroy_enqueuer=(enqueuer : Enqueuer) : Enqueuer
    @@mutex.synchronize { @@enqueuer = enqueuer }
  end

  # Restores the default fiber-backed enqueuer.
  def self.reset_async_destroy_enqueuer : Nil
    self.async_destroy_enqueuer = default_enqueuer
    nil
  end

  private def self.default_enqueuer : Enqueuer
    ->(job : AsyncDestroyJob) do
      spawn { job.perform }
      nil
    end
  end

  # :nodoc:
  def self.register_destroyer(owner_class : String, association : String, destroyer : Destroyer) : Nil
    @@mutex.synchronize do
      updated = @@destroyers.dup
      updated[{owner_class, association}] = destroyer
      @@destroyers = updated
    end
  end

  # :nodoc:
  def self.destroyer_for(owner_class : String, association : String) : Destroyer?
    @@destroyers[{owner_class, association}]?
  end

  # :nodoc:
  def self.enqueue(owner_class : String, association : String, key : Grant::Columns::Type) : Nil
    return if key.nil?
    job_key = key.is_a?(Int64) ? key : (key.is_a?(Int32) ? key.to_i64 : key.to_s)
    async_destroy_enqueuer.call(AsyncDestroyJob.new(owner_class, association, job_key))
  end

  # Rows destroyed per batch by an asynchronous destroy.
  ASYNC_BATCH_SIZE = 1000

  # Raises while compiling when *value* is not a `dependent:` value the
  # *kind* of association supports, so a typo never silently does nothing.
  #
  # :nodoc:
  macro check_dependent_option(kind, association_name, value)
    {% if value %}
      {%
        allowed = if kind == :has_many
                    %w(destroy delete_all nullify restrict restrict_with_exception restrict_with_error destroy_async)
                  elsif kind == :has_one
                    %w(destroy delete nullify restrict restrict_with_exception restrict_with_error destroy_async)
                  else
                    %w(destroy delete destroy_async)
                  end
      %}
      {% unless value.is_a?(SymbolLiteral) && allowed.includes?(value.id.stringify) %}
        {% raise "Unknown `dependent: #{value}` on #{@type}.#{association_name.id} (#{kind.id}). Supported values: #{allowed.map { |name| ":#{name.id}" }.join(", ").id}." %}
      {% end %}
    {% end %}
  end
end

# The instance side of `dependent:`: which association's `dependent: :destroy`
# is destroying this record.
# Holds a reflection behind one pointer, so a record that is not being destroyed
# by an association carries 8 bytes for it instead of the whole struct.
class Grant::Dependent::ReflectionBox
  getter reflection : Grant::Reflection

  def initialize(@reflection : Grant::Reflection)
  end
end

module Grant::Dependent::Instance
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @destroyed_by_association : Grant::Dependent::ReflectionBox?

  # The reflection of the association whose `dependent: :destroy` is destroying
  # this record, or `nil` for a record destroyed directly. Readable from the
  # record's own destroy callbacks.
  #
  # ```
  # after_destroy { skip_notice if destroyed_by_association }
  # ```
  def destroyed_by_association : Grant::Reflection?
    @destroyed_by_association.try(&.reflection)
  end

  # Records which association is destroying this record. Set by
  # `dependent: :destroy` just before it calls `destroy`.
  def destroyed_by_association=(reflection : Grant::Reflection?) : Grant::Reflection?
    @destroyed_by_association = reflection ? Grant::Dependent::ReflectionBox.new(reflection) : nil
    reflection
  end
end

module Grant::AssociationOptions
  # Installs the `after_destroy` / `before_destroy` callbacks behind the
  # `dependent:` association option. Each macro is emitted by an association
  # macro when you pass the matching `dependent:` value; you do not call them
  # directly.
  module DependentCallbacks
    # `dependent: :destroy` destroys the dependents before the owner, inside
    # the same transaction, so foreign-key constraints and callbacks both work.
    # Each dependent knows it was destroyed by the association through
    # `#destroyed_by_association`.
    #
    # ```
    # has_many :comments, dependent: :destroy
    # ```
    macro setup_dependent_destroy(association_name, association_type, target_class, foreign_key, primary_key)
      around_destroy do
        self.class.transaction do
          block.call
        end
      end
      before_destroy do
        reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
        {% if association_type == :has_many %}
          {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).each do |record|
            record.destroyed_by_association = reflection
            abort!("Failed to destroy dependent {{association_name}}") unless record.destroy
          end
        {% elsif association_type == :has_one %}
          if record = {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).first
            record.destroyed_by_association = reflection
            abort!("Failed to destroy dependent {{association_name}}") unless record.destroy
          end
        {% end %}
      end
    end

    # `dependent: :nullify` sets the dependents' foreign key to `nil` with one
    # UPDATE when the owner is destroyed, orphaning them rather than deleting.
    #
    # ```
    # has_many :comments, dependent: :nullify
    # ```
    macro setup_dependent_nullify(association_name, association_type, target_class, foreign_key, primary_key)
      after_destroy do
        {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).update_all([{ {{foreign_key}}, nil.as(Grant::Columns::Type) }])
      end
    end

    # Deletes all dependent records using a single SQL DELETE statement.
    #
    # Unlike `dependent: :destroy`, this does NOT instantiate records or
    # run their callbacks. It performs a direct SQL DELETE for performance.
    #
    # ```
    # has_many :comments, dependent: :delete_all
    # ```
    macro setup_dependent_delete_all(association_name, association_type, target_class, foreign_key, primary_key)
      after_destroy do
        {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).delete_all
      end
    end

    # `dependent: :restrict_with_error` (and its older spelling `:restrict`)
    # blocks the owner's destroy when dependents exist: `destroy` returns `false`
    # and the owner gets a `:base` error. Use `:restrict_with_exception`
    # instead to raise.
    #
    # ```
    # has_many :comments, dependent: :restrict_with_error
    # ```
    macro setup_dependent_restrict(association_name, association_type, target_class, foreign_key, primary_key)
      before_destroy do
        if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
          {% if association_type == :has_many %}
            abort!("Cannot delete record because of dependent {{association_name.id}}")
          {% else %}
            abort!("Cannot delete record because a dependent {{association_name.id}} exists")
          {% end %}
        end
      end
    end

    # `dependent: :restrict_with_exception` raises
    # `Grant::Associations::RestrictError` (also `Grant::DeleteRestrictionError`)
    # when dependent records exist.
    macro setup_dependent_restrict_with_exception(association_name, association_type, target_class, foreign_key, primary_key)
      before_destroy do
        if {{target_class.id}}.where({{foreign_key}}, :eq, self.read_attribute({{primary_key}})).exists?
          raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
        end
      end
    end

    # `dependent: :destroy_async` hands the destroy of the dependents to
    # `Grant::Dependent.async_destroy_enqueuer` once the owner's destroy
    # commits. One job covers the whole association of one owner, however many
    # dependents there are; the job destroys them in batches and is safe to run
    # twice.
    #
    # ```
    # has_many :comments, dependent: :destroy_async
    # ```
    macro setup_dependent_destroy_async(association_name, association_type, target_class, foreign_key, primary_key)
      {% owner_class = @type %}
      Grant::Dependent.register_destroyer({{@type.name.stringify}}, {{association_name.id.stringify}}, ->(key : Int64 | String) : Int64 do
        # A destroy that rolled back leaves the owner in place: keep its dependents.
        return 0_i64 if {{owner_class}}.where({{primary_key}}, :eq, key.as(Grant::Columns::Type)).exists?
        reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
        destroyed = 0_i64
        {{target_class.id}}.where({{foreign_key}}, :eq, key.as(Grant::Columns::Type)).find_each(batch_size: Grant::Dependent::ASYNC_BATCH_SIZE) do |record|
          record.destroyed_by_association = reflection
          destroyed += 1 if record.destroy
        end
        destroyed
      end)

      after_destroy_commit do
        Grant::Dependent.enqueue({{@type.name.stringify}}, {{association_name.id.stringify}}, self.read_attribute({{primary_key}}))
      end
    end

    # `dependent:` on a `has_many ..., through:` acts on the join records, never
    # on the associated records, as in ActiveRecord: `:destroy` destroys them
    # with their callbacks, `:delete_all` and `:nullify` remove them with one
    # DELETE, and the restrict values block the destroy while any associated
    # record exists.
    macro setup_dependent_through(association_name, through_name, strategy)
      {% if strategy == :destroy %}
        before_destroy do
          self.{{through_name.id}}.destroy_all
        end
      {% elsif strategy == :delete_all || strategy == :nullify %}
        before_destroy do
          self.{{through_name.id}}.delete_all(:delete_all)
        end
      {% elsif strategy == :restrict || strategy == :restrict_with_error %}
        before_destroy do
          if self.{{association_name.id}}.exists?
            abort!("Cannot delete record because of dependent {{association_name.id}}")
          end
        end
      {% elsif strategy == :restrict_with_exception %}
        before_destroy do
          if self.{{association_name.id}}.exists?
            raise Grant::Associations::RestrictError.new({{association_name.id.stringify}})
          end
        end
      {% else %}
        {% raise "dependent: #{strategy} is not supported on a has_many with through: (#{association_name.id})" %}
      {% end %}
    end

    # `belongs_to ..., dependent: :destroy` destroys the parent after this
    # record is destroyed; `:delete` removes it with one DELETE and no
    # callbacks; `:destroy_async` queues the destroy. As in ActiveRecord this is
    # rarely right when other records share the parent.
    #
    # ```
    # belongs_to :author, dependent: :destroy
    # ```
    macro setup_dependent_belongs_to(association_name, strategy, target_class, foreign_key, primary_key)
      {% if strategy == :destroy %}
        after_destroy do
          if parent_key = self.read_attribute({{foreign_key}})
            if parent = {{target_class.id}}.where({{primary_key}}, :eq, parent_key).first
              parent.destroyed_by_association = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
              parent.destroy
            end
          end
        end
      {% elsif strategy == :delete %}
        after_destroy do
          if parent_key = self.read_attribute({{foreign_key}})
            {{target_class.id}}.where({{primary_key}}, :eq, parent_key).delete_all
          end
        end
      {% else %}
        Grant::Dependent.register_destroyer({{@type.name.stringify}}, {{association_name.id.stringify}}, ->(key : Int64 | String) : Int64 do
          reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{association_name.id.stringify}})
          destroyed = 0_i64
          {{target_class.id}}.where({{primary_key}}, :eq, key.as(Grant::Columns::Type)).find_each(batch_size: Grant::Dependent::ASYNC_BATCH_SIZE) do |record|
            record.destroyed_by_association = reflection
            destroyed += 1 if record.destroy
          end
          destroyed
        end)

        after_destroy_commit do
          Grant::Dependent.enqueue({{@type.name.stringify}}, {{association_name.id.stringify}}, self.read_attribute({{foreign_key}}))
        end
      {% end %}
    end
  end
end
