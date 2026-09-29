require "./exceptions"

module Grant::Transactions
  # Instance-level write guard: raises Grant::Transaction::ReadOnlyError
  # when the model class has prevent_writes active for the current fiber.
  private def guard_writes!
    self.class.guard_writes!
  end

  module ClassMethods
    # Deletes **every** row from the model's table with a single `DELETE FROM`.
    #
    # This bypasses callbacks and validations entirely — it issues one SQL
    # statement and does not load or instantiate any records. Use it for fast
    # test teardown or truncation, not for normal record removal (use
    # `#destroy` for callback-aware deletion).
    #
    # Returns `nil`.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    # end
    #
    # User.clear # => deletes all users, runs no callbacks
    # User.count # => 0
    # ```
    def clear
      guard_writes!
      query = current_scope
      if !_unscoped? && (_has_default_scope? || (__sti_model? && !sti_root_class?))
        query.delete_all
      else
        adapter.clear table_name
      end
    end

    # Builds a new record from the given keyword attributes and attempts to save
    # it to the database. Returns the new record instance (an instance of the
    # model class).
    #
    # **NOTE**: The returned object is yielded back even when the save failed
    # (e.g. validation errors). The save status is **not** signalled by the
    # return value — inspect `record.errors` / `record.persisted?`, or use
    # `#create!` to raise on failure.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    #   column age : Int32?
    # end
    #
    # user = User.create(email: "ada@example.com", age: 36)
    # user.persisted? # => true (when the save succeeded)
    # user.id         # => 1
    # ```
    def create(**args)
      create(args.to_h)
    end

    # Builds a new record from the *args* hash and attempts to save it to the
    # database. Returns the new record instance.
    #
    # Pass `skip_timestamps: true` to leave `created_at`/`updated_at` untouched
    # (useful when importing historical data). As with the keyword overload, the
    # record is returned regardless of save success — check `record.errors`.
    #
    # ```
    # User.create({"email" => "ada@example.com"})
    # User.create({"email" => "seed@example.com"}, skip_timestamps: true)
    # ```
    def create(args, skip_timestamps : Bool = false)
      guard_writes!
      instance = new
      instance.set_attributes(args.to_h.transform_keys(&.to_s))
      instance.save(skip_timestamps: skip_timestamps)
      instance
    end

    # Builds a new record from the given keyword attributes and saves it,
    # **raising** `Grant::RecordNotSaved` if the save fails (e.g. a validation
    # error). On success, returns the persisted record instance.
    #
    # Use this (over `#create`) when a failed save should halt control flow
    # rather than return an invalid record.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    #   validate :email, "is required", &.email.presence
    # end
    #
    # user = User.create!(email: "ada@example.com") # => persisted User
    # User.create!(email: "")                       # raises Grant::RecordNotSaved
    # ```
    def create!(**args)
      create!(args.to_h)
    end

    # Builds a new record from the *args* hash and saves it, raising
    # `Grant::RecordNotSaved` if the save fails. Returns the persisted record.
    #
    # Pass `skip_timestamps: true` to leave `created_at`/`updated_at` untouched.
    #
    # ```
    # User.create!({"email" => "ada@example.com"})
    # ```
    def create!(args, skip_timestamps : Bool = false)
      guard_writes!
      instance = new
      instance.set_attributes(args.to_h.transform_keys(&.to_s))

      unless instance.save(skip_timestamps: skip_timestamps)
        if instance.errors.empty?
          instance.errors << Grant::Error.new(:base, "Save was halted before the record was persisted.")
        end
        raise instance.save_failure_error
      end

      instance
    end

    # Bulk-inserts every record in *model_array* using batched `INSERT`
    # statements — far faster than calling `#save` per record.
    #
    # All elements must be instances of this model class. `before_save` /
    # `before_create` and `after_create` / `after_save` callbacks run per record,
    # but **validations are not run** and invalid records are not skipped at the
    # ORM level (database constraint violations still raise). Each
    # `batch_size`-sized slice is sent as one multi-row `INSERT`; the default
    # batch size is the whole array (one statement).
    #
    # Raises `DB::Error` on a failed insert (and re-raises
    # `Grant::Transaction::ReadOnlyError` if writes are blocked). The return
    # value is the iterated *model_array* and should not be relied upon.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    # end
    #
    # users = (1..1000).map { |i| User.new(email: "user#{i}@example.com") }
    # User.import(users)                  # one INSERT for all 1000 rows
    # User.import(users, batch_size: 100) # ten INSERTs of 100 rows each
    # ```
    def import(model_array : Array(self) | Grant::Collection(self), batch_size : Int32 = model_array.size)
      guard_writes!
      {% begin %}
        {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
        {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
        {% ann = primary_key.annotation(Grant::Column) %}
        fields_duplicate = fields.dup
        model_array.each_slice(batch_size, true) do |slice|
          slice.each do |i|
            i.before_save
            i.before_create
          end
          adapter.import(table_name, {{primary_key.name.stringify}}, {{ann[:auto]}}, fields_duplicate, slice)
          slice.each do |i|
            i.after_create
            i.after_save
          end
        end
      {% end %}
    rescue ex : Grant::Transaction::ReadOnlyError | Grant::StatementInvalid
      raise ex
    rescue err
      raise DB::Error.new(err.message, cause: err)
    end

    # Bulk-inserts *model_array* as an upsert: when a row collides with an
    # existing primary/unique key, the columns named in *columns* are updated
    # instead of the insert failing (an `ON DUPLICATE KEY UPDATE` / `ON CONFLICT
    # DO UPDATE`-style operation, depending on adapter).
    #
    # Pass `update_on_duplicate: true` and the list of *columns* to overwrite on
    # conflict. Callbacks run as in the basic `#import`; validations do not.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    #   column age : Int32?
    # end
    #
    # users = [User.new(id: 1_i64, email: "ada@example.com", age: 37)]
    # # If a user with id 1 already exists, overwrite only its age column:
    # User.import(users, update_on_duplicate: true, columns: ["age"])
    # ```
    def import(model_array : Array(self) | Grant::Collection(self), update_on_duplicate : Bool, columns : Array(String), batch_size : Int32 = model_array.size)
      guard_writes!
      {% begin %}
        {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
        {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
        {% ann = primary_key.annotation(Grant::Column) %}
        fields_duplicate = fields.dup
        model_array.each_slice(batch_size, true) do |slice|
          slice.each do |i|
            i.before_save
            i.before_create
          end
          adapter.import(table_name, {{primary_key.name.stringify}}, {{ann[:auto]}}, fields_duplicate, slice, update_on_duplicate: update_on_duplicate, columns: columns)
          slice.each do |i|
            i.after_create
            i.after_save
          end
        end
      {% end %}
    rescue ex : Grant::Transaction::ReadOnlyError | Grant::StatementInvalid
      raise ex
    rescue err
      raise DB::Error.new(err.message, cause: err)
    end

    # Bulk-inserts *model_array*, silently skipping rows that would violate a
    # primary/unique key (an `INSERT IGNORE` / `ON CONFLICT DO NOTHING`-style
    # operation, depending on adapter).
    #
    # Pass `ignore_on_duplicate: true` to drop colliding rows instead of raising.
    # Callbacks run as in the basic `#import`; validations do not.
    #
    # ```
    # class User < Grant::Base
    #   column id : Int64, primary: true
    #   column email : String
    # end
    #
    # users = [User.new(id: 1_i64, email: "ada@example.com")]
    # # If id 1 already exists, this row is skipped rather than raising:
    # User.import(users, ignore_on_duplicate: true)
    # ```
    def import(model_array : Array(self) | Grant::Collection(self), ignore_on_duplicate : Bool, batch_size : Int32 = model_array.size)
      guard_writes!
      {% begin %}
        {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
        {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
        {% ann = primary_key.annotation(Grant::Column) %}
        fields_duplicate = fields.dup
        model_array.each_slice(batch_size, true) do |slice|
          slice.each do |i|
            i.before_save
            i.before_create
          end
          adapter.import(table_name, {{primary_key.name.stringify}}, {{ann[:auto]}}, fields_duplicate, slice, ignore_on_duplicate: ignore_on_duplicate)
          slice.each do |i|
            i.after_create
            i.after_save
          end
        end
      {% end %}
    rescue ex : Grant::Transaction::ReadOnlyError | Grant::StatementInvalid
      raise ex
    rescue err
      raise DB::Error.new(err.message, cause: err)
    end
  end

  # Sets the record's `created_at` and/or `updated_at` columns to *time*
  # (default: now in the configured default timezone).
  #
  # This is a low-level helper invoked automatically by `#save`; you rarely call
  # it directly. With `mode: :create` both timestamps are set; with
  # `mode: :update` only `updated_at` is touched. Columns that the model doesn't
  # declare are skipped. Sub-second precision is preserved.
  #
  # ```
  # user.set_timestamps                           # create mode: sets both
  # user.set_timestamps(mode: :update)            # only updated_at
  # user.set_timestamps(to: Time.utc(2020, 1, 1)) # pin a specific time
  # ```
  def set_timestamps(*, to time = Time.local(Grant.settings.default_timezone), mode = :create)
    {% if @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.type == Time? }.map(&.name.stringify).includes? "created_at" %}
      if mode == :create
        @created_at = time
      end
    {% end %}

    {% if @type.instance_vars.select { |ivar| ivar.annotation(Grant::Column) && ivar.type == Time? }.map(&.name.stringify).includes? "updated_at" %}
      @updated_at = time
    {% end %}
  end

  private def __create(skip_timestamps : Bool = false)
    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
      # Composite keys handled by CompositePrimaryKey module
      {% if @type.instance_vars.select { |ivar| ann = ivar.annotation(Grant::Column); ann && ann[:primary] }.size > 1 %}
        # Skip standard implementation for composite keys
        return if self.class.responds_to?(:composite_primary_key?) && self.class.composite_primary_key?
      {% end %}
      {% ann = primary_key.annotation(Grant::Column) %}

      Grant::Logs::Model.debug { "Creating record - #{self.class.name}" }

      set_timestamps unless skip_timestamps
      fields = self.class.content_fields.dup
      params = content_values

      if value = @{{primary_key.name.id}}
        fields << {{primary_key.name.stringify}}
        params << value
      end

      {% if primary_key.type == Int32? && ann[:auto] == true %}
        if @{{primary_key.name.id}}
          self.class.adapter.insert(self.class.table_name, fields, params, lastval: nil)
        else
          @{{primary_key.name.id}} = self.class.adapter.insert(self.class.table_name, fields, params, lastval: {{primary_key.name.stringify}}).to_i32
        end
      {% elsif primary_key.type == Int64? && ann[:auto] == true %}
        if @{{primary_key.name.id}}
          self.class.adapter.insert(self.class.table_name, fields, params, lastval: nil)
        else
          @{{primary_key.name.id}} = self.class.adapter.insert(self.class.table_name, fields, params, lastval: {{primary_key.name.stringify}})
        end
      {% elsif primary_key.type == UUID? && ann[:auto] == true %}
          # if the primary key has not been set, then do so

          unless fields.includes?({{primary_key.name.stringify}})
            _uuid = UUID.random
            @{{primary_key.name.id}} = _uuid
            params << _uuid
            fields << {{primary_key.name.stringify}}
          end
          self.class.adapter.insert(self.class.table_name, fields, params, lastval: nil)
      {% elsif ann[:auto] == true %}
        {% raise "Failed to define #{@type.name}#save: Primary key must be Int(32|64) or UUID, or set `auto: false` for natural keys.\n\n  column #{primary_key.name} : #{primary_key.type}, primary: true, auto: false\n" %}
      {% else %}
        if @{{primary_key.name.id}}
          self.class.adapter.insert(self.class.table_name, fields, params, lastval: nil)
        else
          message = "Primary key('{{primary_key.name}}') cannot be null"
          errors << Grant::Error.new({{primary_key.name.stringify}}, message)
          raise DB::Error.new
        end
      {% end %}
    {% end %}
  rescue err : DB::Error | Grant::StatementInvalid
    Grant::Logs::Model.error { "Failed to create record - #{self.class.name} - #{err.message}" }
    raise err
  rescue err
    Grant::Logs::Model.error { "Failed to create record - #{self.class.name} - #{err.message}" }
    raise DB::Error.new(err.message, cause: err)
  else
    self.new_record = false

    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      Grant::Logs::Model.info { "Record created - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }
    {% end %}
  end

  private def __update(skip_timestamps : Bool = false)
    return if __update_with_optimistic_lock(skip_timestamps)

    {% begin %}
    {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
    {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
    {% ann = primary_key.annotation(Grant::Column) %}
    
    # Record-level read-only guard: a record flagged via `#readonly!` (or loaded
    # through a read-only relation) cannot be persisted. Mirrors AR.
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?

    Grant::Logs::Model.debug { "Updating record - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }

    set_timestamps(mode: :update) unless skip_timestamps
      fields = self.class.content_fields.dup
      params = content_values + [@{{primary_key.name.id}}]

    # Do not update created_at on update
    if created_at_index = fields.index("created_at")
      fields.delete_at created_at_index
      params.delete_at created_at_index
    end

    # Exclude any columns declared with `attr_readonly` — they are writable on
    # create, but ignored on update (mirrors ActiveRecord).
    self.class.readonly_attributes.each do |readonly_field|
      if readonly_index = fields.index(readonly_field)
        fields.delete_at readonly_index
        params.delete_at readonly_index
      end
    end

    begin
      if self.class.__multitenant?
        assignments = [] of Tuple(String, Grant::Columns::Type)
        fields.each_with_index do |field, index|
          assignments << {field, params[index]}
        end
        affected = self.class.__tenant_write_scope
          .where(self.class.primary_name, :eq, @{{primary_key.name.id}}.as(Grant::Columns::Type))
          .update_all(assignments)
        if affected == 0 && !self.class._unscoped?
          row_is_in_scope = self.class.__tenant_write_scope
            .where(self.class.primary_name, :eq, @{{primary_key.name.id}}.as(Grant::Columns::Type))
            .exists?
          unless row_is_in_scope
            raise Grant::TenantMismatchError.new("#{self.class.name} row #{@{{primary_key.name.id}}} is outside the current tenant.")
          end
        end
      else
        self.class.adapter.update(self.class.table_name, self.class.primary_name, fields, params)
      end
     
     Grant::Logs::Model.info { "Record updated - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }
    rescue ex : Grant::TenantMismatchError | Grant::NoTenantError | Grant::StatementInvalid
      raise ex
    rescue err
      Grant::Logs::Model.error { "Failed to update record - #{self.class.name} [id: #{@{{primary_key.name.id}}}] - #{err.message}" }
      raise DB::Error.new(err.message, cause: err)
    end
  {% end %}
  end

  # Gives locking modules one place to replace the normal primary-key update
  # with an atomic conditional write. Returns true when the module performed
  # the update itself.
  protected def __update_with_optimistic_lock(skip_timestamps : Bool = false) : Bool
    false
  end

  private def __destroy
    {% begin %}
    {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
    {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
    {% ann = primary_key.annotation(Grant::Column) %}
    
    Grant::Logs::Model.debug { "Destroying record - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }
    
    if self.class.__multitenant?
      affected = self.class.__tenant_write_scope
        .where(self.class.primary_name, :eq, @{{primary_key.name.id}}.as(Grant::Columns::Type))
        .delete_all
      if affected == 0 && !self.class._unscoped?
        raise Grant::TenantMismatchError.new("#{self.class.name} row #{@{{primary_key.name.id}}} is outside the current tenant.")
      end
    else
      self.class.adapter.delete(self.class.table_name, self.class.primary_name, @{{primary_key.name.id}})
    end
    @destroyed = true
    
    Grant::Logs::Model.info { "Record destroyed - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }
  {% end %}
  end

  # Persists the record to the database, returning `true` on success and `false`
  # on failure. On failure, `#errors` is populated with the reasons.
  #
  # Works for both new and existing records: a new record (`new_record?`) is
  # `INSERT`ed, an existing one is `UPDATE`d. Lifecycle callbacks
  # (`before_save`/`after_create`/`after_update`/`after_save`, plus commit
  # callbacks inside a transaction) run around the write. The operation is
  # transactional, so an abort from any save callback rolls the write back.
  #
  # - `validate: false` skips validations (the record is written even if
  #   invalid). Callbacks still run.
  # - `skip_timestamps: true` leaves `created_at`/`updated_at` untouched.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  # end
  #
  # user = User.new(email: "ada@example.com")
  # user.save # => true; INSERTs a new row
  # user.email = "ada2@example.com"
  # user.save                  # => true; UPDATEs the existing row
  # user.save(validate: false) # write regardless of validation state
  # ```
  def save(*, validate : Bool = true, skip_timestamps : Bool = false) : Bool
    guard_writes!
    {% begin %}
    {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
    {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}
    {% ann = primary_key.annotation(Grant::Column) %}

    @last_save_failed_validation = false
    @last_save_statement_error = nil
    save_succeeded = true
    save_failed = false
    failure_message : String? = nil
    save_transaction = Grant::Transaction::Options.new(
      requires_new: Grant::Transaction.in_explicit_transaction? &&
        Grant::Transaction.current_connection?(self.class.adapter).nil?
    )

    self.class.transaction(save_transaction) do
      enlist_transaction_record

      begin
        if validate
          validation_context = (@{{primary_key.name.id}} && !new_record?) ? :update : :create
          unless valid?(context: validation_context)
            @last_save_failed_validation = true
            save_succeeded = false
            next
          end
        end

        __run_around_save do
          __before_save
          if @{{primary_key.name.id}} && !new_record?
            __run_around_update do
              __before_update
              __update(skip_timestamps: skip_timestamps)
              __after_update
              queue_commit_callback(:after_update_commit) if responds_to?(:queue_commit_callback)
            end
          else
            __run_around_create do
              __before_create
              __create(skip_timestamps: skip_timestamps)
              __after_create
              queue_commit_callback(:after_create_commit) if responds_to?(:queue_commit_callback)
            end
          end
          __after_save unless around_halted?
          queue_commit_callback(:after_commit) if responds_to?(:queue_commit_callback) && !around_halted?
          run_commit_callbacks if responds_to?(:run_commit_callbacks) && !around_halted?
        end
        save_succeeded = !around_halted?
      rescue ex : DB::Error | Grant::StatementInvalid | Grant::Callbacks::Abort
        save_failed = true
        @last_save_statement_error = ex if ex.is_a?(Grant::StatementInvalid)
        if message = ex.message
          errors << Grant::Error.new(:base, message)
        end

        clear_commit_callbacks if responds_to?(:clear_commit_callbacks)
        Grant::Transaction.enqueue_pending_callback(
          Proc(Nil).new { },
          Proc(Nil).new { after_rollback if responds_to?(:after_rollback) }
        )
        raise Grant::Transaction::Rollback.new
      end
    end

    if save_failed
      if message = failure_message
        Log.error { "Save Exception: #{message}" }

        {% begin %}
        {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
        Grant::Logs::Model.error { "Failed to save record - #{self.class.name} [id: #{@{{primary_key.name.id}}}] [new_record: #{new_record?}] - #{message}" }
        {% end %}
      end
      return false
    end

    save_succeeded
  {% end %}
  end

  # Persists the record like `#save`, but **raises** `Grant::RecordNotSaved`
  # instead of returning `false` when the save fails. Returns `true` on success.
  #
  # Use this when a failed save should abort the current flow (e.g. inside a
  # `transaction` so the failure triggers a rollback).
  #
  # ```
  # user = User.new(email: "ada@example.com")
  # user.save! # => true, or raises Grant::RecordNotSaved
  # ```
  def save!(*, validate : Bool = true, skip_timestamps : Bool = false) : Bool
    save(validate: validate, skip_timestamps: skip_timestamps) || raise save_failure_error
  end

  # True while the most recent `#save` on this record stopped at validation, so
  # the bang methods can raise `Grant::RecordInvalid` rather than the more
  # general `Grant::RecordNotSaved`.
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @last_save_failed_validation : Bool = false

  # The database error that stopped the most recent `#save`, already
  # translated (`Grant::RecordNotUnique`, `Grant::InvalidForeignKey`, ...).
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  @last_save_statement_error : Grant::StatementInvalid?

  # The exception the bang methods raise for the most recent failed save:
  # `Grant::RecordInvalid` for a validation failure, `Grant::RecordNotSaved`
  # for anything else (a callback abort, a database error recorded on the
  # record). Its message is always safe to build, even when no error was
  # recorded on the record.
  #
  # :nodoc:
  def save_failure_error : Grant::RecordNotSaved
    if @last_save_failed_validation
      Grant::RecordInvalid.new(self)
    else
      Grant::RecordNotSaved.new(self.class.name, self, @last_save_statement_error)
    end
  end

  # Assigns the given keyword attributes to the record and saves it, returning
  # `true` if the save succeeded and `false` otherwise. Runs validations and
  # callbacks (it is `#save` under the hood). On failure, see `#errors`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  #   column age : Int32?
  # end
  #
  # user = User.find!(1)
  # user.update(email: "new@example.com", age: 40) # => true
  # ```
  def update(**args) : Bool
    update(args.to_h)
  end

  # Assigns the attributes in the *args* hash to the record and saves it.
  # Returns `true` on success, `false` on failure.
  #
  # Pass `skip_timestamps: true` to leave `updated_at` untouched.
  #
  # ```
  # user.update({"email" => "new@example.com"})
  # user.update({"email" => "seed@example.com"}, skip_timestamps: true)
  # ```
  def update(args, skip_timestamps : Bool = false) : Bool
    enlist_transaction_record
    set_attributes(args.to_h.transform_keys(&.to_s))

    save(skip_timestamps: skip_timestamps)
  end

  # Assigns the given keyword attributes and saves the record, **raising**
  # `Grant::RecordNotSaved` if the save fails. Returns `true` on success. Runs
  # validations and callbacks.
  #
  # ```
  # user = User.find!(1)
  # user.update!(email: "new@example.com") # => true, or raises Grant::RecordNotSaved
  # ```
  def update!(**args) : Bool
    update!(args.to_h)
  end

  # Assigns the attributes in the *args* hash and saves the record, raising
  # `Grant::RecordNotSaved` if the save fails. Returns `true` on success.
  #
  # Pass `skip_timestamps: true` to leave `updated_at` untouched.
  #
  # ```
  # user.update!({"email" => "new@example.com"})
  # ```
  def update!(args, skip_timestamps : Bool = false) : Bool
    enlist_transaction_record
    set_attributes(args.to_h.transform_keys(&.to_s))

    save!(skip_timestamps: skip_timestamps)
  end

  # Updates a single attribute and persists the record, **skipping validations**
  # but still running callbacks (mirrors ActiveRecord's `update_attribute`).
  #
  # Returns `true` if the save succeeded, `false` otherwise. Because validations
  # are skipped, this writes even values a validator would reject — use it
  # deliberately.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  # end
  #
  # user = User.find!(1)
  # user.update_attribute(:email, "new@example.com") # => true (even if validations would fail)
  # ```
  def update_attribute(name : Symbol | String, value) : Bool
    enlist_transaction_record
    write_attribute(name.to_s, value.as(Grant::Columns::Type))
    save(validate: false)
  end

  # Updates a single attribute and persists the record (skipping validations,
  # running callbacks), **raising** `Grant::RecordNotSaved` if the save fails.
  # Returns `true` on success.
  #
  # ```
  # user.update_attribute!(:email, "new@example.com") # => true, or raises
  # ```
  def update_attribute!(name : Symbol | String, value) : Bool
    update_attribute(name, value) || raise save_failure_error
  end

  # Updates the given columns directly in the database, **skipping validations,
  # callbacks, and timestamp updates**. The in-memory record is updated to match.
  #
  # Uses a parameterized `UPDATE` (no string interpolation of values). Returns
  # `true` on success. Raises if the record is a new (unsaved) record, has been
  # marked read-only, or no columns are given. Mirrors ActiveRecord's
  # `update_columns`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  # end
  #
  # user = User.find!(1)
  # user.update_columns(email: "direct@example.com") # => true, no callbacks fire
  # ```
  def update_columns(**args) : Bool
    update_columns(args.to_h)
  end

  # Updates the given columns directly in the database (hash form). See the
  # keyword-argument overload above; *args* is a `Grant::ModelArgs`
  # (`Hash(String | Symbol, Grant::Columns::Type)`).
  #
  # ```
  # user.update_columns({"email" => "direct@example.com"})
  # ```
  def update_columns(args : Grant::ModelArgs) : Bool
    guard_writes!
    __ensure_current_tenant!
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    raise "Cannot update columns on a new record object" unless persisted?
    raise ArgumentError.new("No columns given to update_columns") if args.empty?

    enlist_transaction_record

    {% begin %}
      {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
      {% raise raise "A primary key must be defined for #{@type.name}." unless primary_key %}

      string_args = args.to_h.transform_keys(&.to_s)
      readonly_field = string_args.keys.find { |column_name| self.class.readonly_attributes.includes?(column_name) }
      if readonly_field
        raise Grant::ReadOnlyRecordError.new("#{self.class.name}##{readonly_field} is read only")
      end

      persisted_primary_key = @{{primary_key.name.id}}
      fields = [] of String
      params = [] of Grant::Columns::Type
      string_args.each do |column_name, value|
        # The generated writer validates the attribute type and tracks it.
        write_attribute(column_name, value.as(Grant::Columns::Type))
        fields << column_name
        params << read_attribute(column_name)
      end

      __ensure_current_tenant!
      self.class.mark_write_operation

      if self.class.__multitenant?
        assignments = [] of Tuple(String, Grant::Columns::Type)
        fields.each_with_index do |field, index|
          assignments << {field, params[index]}
        end
        affected = self.class.__tenant_write_scope
          .where(self.class.primary_name, :eq, persisted_primary_key.as(Grant::Columns::Type))
          .update_all(assignments)
        if affected == 0 && !self.class._unscoped?
          row_is_in_scope = self.class.__tenant_write_scope
            .where(self.class.primary_name, :eq, persisted_primary_key.as(Grant::Columns::Type))
            .exists?
          unless row_is_in_scope
            raise Grant::TenantMismatchError.new("#{self.class.name} row #{persisted_primary_key} is outside the current tenant.")
          end
        end
        clear_dirty_tracking_for(fields)
        return true
      end

      params << persisted_primary_key

      begin
        self.class.adapter.update(self.class.table_name, self.class.primary_name, fields, params)
        Grant::Logs::Model.info { "Columns updated - #{self.class.name} [id: #{@{{primary_key.name.id}}}]" }
      rescue err : Grant::StatementInvalid
        Grant::Logs::Model.error { "Failed to update_columns - #{self.class.name} [id: #{persisted_primary_key}] - #{err.message}" }
        raise err
      rescue err
        Grant::Logs::Model.error { "Failed to update_columns - #{self.class.name} [id: #{persisted_primary_key}] - #{err.message}" }
        raise DB::Error.new(err.message, cause: err)
      end
      clear_dirty_tracking_for(fields)
    {% end %}

    true
  end

  # Increments the in-memory value of a numeric *field* by *by* (default `1`)
  # **without persisting**. Returns `self` so calls can be chained. A `nil`
  # current value is treated as `0`. Raises if the field is non-numeric.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column login_count : Int32
  # end
  #
  # user.increment(:login_count)        # +1 in memory only
  # user.increment(:login_count, by: 5) # +5 in memory only
  # user.save                           # persist the change
  # ```
  def increment(field : Symbol | String, by = 1) : self
    current = read_attribute(field.to_s)
    raise "Cannot increment non-numeric attribute #{field}" unless current.is_a?(Number) || current.nil?
    new_value = (current.nil? ? 0 : current) + by
    write_attribute(field.to_s, new_value.as(Grant::Columns::Type))
    self
  end

  # Increments a numeric *field* by *by* (default `1`) and persists only that
  # counter with an atomic database update. Other pending changes remain dirty.
  # Validations and save callbacks are skipped. Returns `self`.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column login_count : Int32
  # end
  #
  # user = User.find!(1)
  # user.increment!(:login_count)        # +1 and UPDATE
  # user.increment!(:login_count, by: 3) # +3 and UPDATE
  # ```
  def increment!(field : Symbol | String, by = 1) : self
    guard_writes!
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    __ensure_current_tenant!
    enlist_transaction_record

    if new_record?
      increment(field, by)
      save(validate: false)
      return self
    end

    attribute_name = field.to_s
    if self.class.readonly_attributes.includes?(attribute_name)
      raise Grant::ReadOnlyRecordError.new("#{self.class.name}##{attribute_name} is read only")
    end

    current_value = read_attribute(attribute_name)
    raise "Cannot increment non-numeric attribute #{field}" unless current_value.is_a?(Number) || current_value.nil?

    updated_value = (current_value.nil? ? 0 : current_value) + by
    write_attribute(attribute_name, updated_value.as(Grant::Columns::Type))
    primary_key_value = self.primary_key_value.as(Grant::Columns::Type)

    query = if self.class.__multitenant?
              self.class.__tenant_write_scope
            else
              self.class.unscoped
            end
    assembler = query.where(self.class.primary_name, :eq, primary_key_value).assembler
    where_clause = assembler.where || raise Grant::Querying::MissingWhereClauseError.new("Increment query has no WHERE clause")

    self.class.mark_write_operation
    affected = self.class.adapter.increment_with_where(
      self.class.table_name,
      attribute_name,
      by.as(Grant::Columns::Type),
      where_clause,
      assembler.numbered_parameters
    )
    if affected == 0 && self.class.__multitenant? && !self.class._unscoped?
      row_is_in_scope = self.class.__tenant_write_scope
        .where(self.class.primary_name, :eq, primary_key_value)
        .exists?
      unless row_is_in_scope
        raise Grant::TenantMismatchError.new("#{self.class.name} row #{primary_key_value} is outside the current tenant.")
      end
    end

    clear_dirty_tracking_for([attribute_name])
    self
  end

  # Decrements the in-memory value of a numeric *field* by *by* (default `1`)
  # **without persisting**. Returns `self` for chaining. Equivalent to
  # `increment(field, -by)`.
  #
  # ```
  # user.decrement(:login_count)        # -1 in memory only
  # user.decrement(:login_count, by: 2) # -2 in memory only
  # ```
  def decrement(field : Symbol | String, by = 1) : self
    increment(field, -by)
  end

  # Decrements a numeric *field* by *by* (default `1`) and atomically persists
  # only that counter. Other pending changes stay dirty; validations and save
  # callbacks are skipped. Returns `self`. Mirrors ActiveRecord's `decrement!`.
  #
  # ```
  # user = User.find!(1)
  # user.decrement!(:login_count) # -1 and UPDATE
  # ```
  def decrement!(field : Symbol | String, by = 1) : self
    increment!(field, -by)
  end

  # Flips the in-memory boolean value of *field* **without persisting**. Returns
  # `self` for chaining. A `nil` value is treated as `false` (flips to `true`).
  # Raises if the field is non-boolean.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column active : Bool
  # end
  #
  # user.toggle(:active) # active becomes !active, in memory only
  # user.save            # persist the change
  # ```
  def toggle(field : Symbol | String) : self
    current = read_attribute(field.to_s)
    raise "Cannot toggle non-boolean attribute #{field}" unless current.is_a?(Bool) || current.nil?
    write_attribute(field.to_s, (!current).as(Grant::Columns::Type))
    self
  end

  # Flips the boolean value of *field* **and persists** the record (via
  # `save(validate: false)` — validations skipped, callbacks run). Returns
  # `self`. Mirrors ActiveRecord's `toggle!`.
  #
  # ```
  # user = User.find!(1)
  # user.toggle!(:active) # active flipped and UPDATEd
  # ```
  def toggle!(field : Symbol | String) : self
    enlist_transaction_record
    toggle(field)
    save(validate: false)
    self
  end

  # Deletes this record without running destroy callbacks. Returns `self` and
  # marks the instance destroyed after the delete succeeds. For a multitenant
  # model, a zero-row delete raises when the record is outside the current tenant.
  def delete : self
    guard_writes!
    __ensure_current_tenant!
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    enlist_transaction_record

    if persisted?
      persisted_primary_key = primary_key_value.as(Grant::Columns::Type)
      self.class.mark_write_operation

      if self.class.__multitenant?
        affected = self.class.__tenant_write_scope
          .where(self.class.primary_name, :eq, persisted_primary_key)
          .delete_all
        if affected == 0 && !self.class._unscoped?
          raise Grant::TenantMismatchError.new("#{self.class.name} row #{persisted_primary_key} is outside the current tenant.")
        end
      else
        self.class.adapter.delete_with_rows_affected(
          self.class.table_name,
          self.class.primary_name,
          persisted_primary_key
        )
      end
    end

    mark_destroyed
    self
  end

  # Deletes the record's row from the database, returning `true` on success and
  # `false` otherwise. Runs `before_destroy`/`after_destroy` (and
  # `after_destroy_commit`/`after_commit`) callbacks, and marks the in-memory
  # record `destroyed?`.
  #
  # Raises `Grant::ReadOnlyRecordError` if the record is marked read-only. Unlike
  # `.clear`, this is callback-aware and operates on a single loaded record.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String
  # end
  #
  # user = User.find!(1)
  # user.destroy    # => true
  # user.destroyed? # => true
  # ```
  def destroy : Bool
    guard_writes!
    enlist_transaction_record
    # Record-level read-only guard. Mirrors ActiveRecord's ReadOnlyRecord.
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    begin
      __run_around_destroy do
        __before_destroy
        __destroy
        __after_destroy
        queue_commit_callback(:after_destroy_commit) if responds_to?(:queue_commit_callback)
        queue_commit_callback(:after_commit) if responds_to?(:queue_commit_callback)
        run_commit_callbacks if responds_to?(:run_commit_callbacks)
      end
      return false if around_halted?
    rescue ex : DB::Error | Grant::StatementInvalid | Grant::Callbacks::Abort
      if message = ex.message
        Log.error { "Destroy Exception: #{message}" }
        errors << Grant::Error.new(:base, message)

        {% begin %}
        {% primary_key = @type.instance_vars.find { |ivar| (ann = ivar.annotation(Grant::Column)) && ann[:primary] } %}
        Grant::Logs::Model.error { "Failed to destroy record - #{self.class.name} [id: #{@{{primary_key.name.id}}}] - #{message}" }
        {% end %}
      end
      run_rollback_callbacks if responds_to?(:run_rollback_callbacks)
      return false
    end
    true
  end

  # Deletes the record like `#destroy`, but **raises**
  # `Grant::RecordNotDestroyed` instead of returning `false` when the delete
  # fails (e.g. a `before_destroy` callback aborts). Returns `true` on success.
  #
  # ```
  # user = User.find!(1)
  # user.destroy! # => true, or raises Grant::RecordNotDestroyed
  # ```
  def destroy! : Bool
    destroy || raise Grant::RecordNotDestroyed.new(self.class.name, self)
  end

  # Sets `updated_at` (and any extra `Time` *fields* named) to the current time
  # and writes only those fields. Other pending changes remain dirty. Runs
  # `after_touch` and the transaction-aware `after_commit` callback.
  #
  # Each name in *fields* must be a `Time` column on the model; a non-`Time` or
  # unknown field raises. Raises if the record is not yet persisted.
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column last_seen_at : Time?
  #   timestamps
  # end
  #
  # user = User.find!(1)
  # user.touch                # bumps updated_at only
  # user.touch(:last_seen_at) # bumps updated_at and last_seen_at
  # ```
  def touch(*fields) : Bool
    guard_writes!
    raise "Cannot touch on a new record object" unless persisted?
    raise Grant::ReadOnlyRecordError.new("#{self.class.name} is marked as read only") if readonly?
    __ensure_current_tenant!
    enlist_transaction_record

    touch_time = Time.local(Grant.settings.default_timezone)
    touch_fields = [] of String

    {% if @type.instance_vars.any? { |ivar| ivar.annotation(Grant::Column) && ivar.name.stringify == "updated_at" && (ivar.type == Time? || ivar.type == Time) } %}
      if self.class.readonly_attributes.includes?("updated_at")
        raise Grant::ReadOnlyRecordError.new("#{self.class.name}#updated_at is read only")
      end
      self.updated_at = touch_time
      touch_fields << "updated_at"
    {% end %}

    {% begin %}
      fields.each do |field|
        case field.to_s
          {% for time_field in @type.instance_vars.select { |ivar| ivar.type == Time? || ivar.type == Time } %}
            when {{time_field.stringify}}
              if self.class.readonly_attributes.includes?({{time_field.stringify}})
                raise Grant::ReadOnlyRecordError.new("#{self.class.name}#" + {{time_field.stringify}} + " is read only")
              end
              self.{{time_field.id}} = touch_time
              touch_fields << {{time_field.stringify}} unless touch_fields.includes?({{time_field.stringify}})
          {% end %}
        else
          if {{@type.instance_vars.map(&.name.stringify)}}.includes? field.to_s
            raise "{{@type.name}}.#{field} cannot be touched.  It is not of type `Time`."
          else
            raise "Field '#{field}' does not exist on type '{{@type.name}}'."
          end
        end
      end
    {% end %}

    raise ArgumentError.new("No timestamp columns are available to touch") if touch_fields.empty?
    touch_assignments = Grant::ModelArgs.new
    touch_fields.each do |field_name|
      touch_assignments[field_name] = read_attribute(field_name)
    end

    result = update_columns(touch_assignments)
    if result
      after_touch if responds_to?(:after_touch)
      queue_commit_callback(:after_commit) if responds_to?(:queue_commit_callback)
      run_commit_callbacks if responds_to?(:run_commit_callbacks)
    end
    result
  end
end
