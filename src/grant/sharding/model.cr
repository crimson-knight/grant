require "set"

module Grant::Sharding
  # Raised when a save or column write would change a shard-key column of a
  # persisted record. The row lives on the shard its key resolved to when it
  # was written, so changing the key in place would strand it. Use
  # `move_to_shard` to relocate a record.
  class ShardKeyChangedError < Grant::ErrorBase
  end

  # Raised when a join links a sharded model to a table that is not stored on
  # the same shard as the rows it joins. Each shard is its own database, so
  # such a join would see only the rows that happen to share a shard.
  class CrossShardJoinError < Grant::ErrorBase
  end

  # Whether two shard configurations place rows identically, so a join between
  # their models stays inside one shard: the same declaration, or the same
  # shard-key columns with an equal hash or lookup placement.
  def self.colocated?(left : ShardConfig, right : ShardConfig) : Bool
    return true if left.same?(right)
    return false unless left.key_column_names == right.key_column_names

    left_resolver = left.resolver
    right_resolver = right.resolver
    return true if left_resolver.same?(right_resolver)

    if left_resolver.is_a?(HashResolver) && right_resolver.is_a?(HashResolver)
      left_resolver.all_shards == right_resolver.all_shards
    elsif left_resolver.is_a?(LookupResolver) && right_resolver.is_a?(LookupResolver)
      left_resolver.lookup_table == right_resolver.lookup_table && left_resolver.default_shard == right_resolver.default_shard
    else
      false
    end
  end

  module Model
    # Class-level API `Grant::Sharding::Model` adds to a model.
    module ClassMethods
      # Yields every record of every shard, one shard after another, with the
      # record's `current_shard` set. Each shard is read in keyset batches
      # (`WHERE id > last_id ORDER BY id LIMIT n`), so cost stays linear and a
      # record shows up exactly once. The batch options are those of
      # `Builder#find_each`.
      #
      # ```
      # Account.find_each_shard(batch_size: 500) { |account| audit(account) }
      # ```
      def find_each_shard(batch_size : Int32 = 1000, start : Grant::Columns::Type = nil, finish : Grant::Columns::Type = nil, order : Symbol = :asc, error_on_ignore : Bool = false, &) : Nil
        Grant::ShardManager.shards_for_model(name).each do |shard|
          __builder.on_shard(shard).find_each(batch_size: batch_size, start: start, finish: finish, order: order, error_on_ignore: error_on_ignore) do |record|
            yield record
          end
        end
      end
    end

    # The shard this record lives on: set when a sharded query loads it or
    # when it is first written, or by hand.
    @current_shard : Symbol?
    # The shard-key values @current_shard was resolved from. Nil while the
    # shard was set by hand or by a query, which never re-resolve.
    @shard_derived_from : Array(Grant::Columns::Type)?

    def current_shard : Symbol?
      @current_shard
    end

    # Pins the record to *shard*; it is not resolved from the key again.
    def current_shard=(shard : Symbol?) : Symbol?
      @shard_derived_from = nil
      @current_shard = shard
    end

    # The shard this record belongs on. A loaded or pinned record answers with
    # the shard it lives on. A new record resolves its key once and caches the
    # answer until a shard-key value changes.
    def determine_shard : Symbol
      config = self.class.sharding_config || raise "Model #{self.class.name} is not configured for sharding"

      cached = @current_shard
      derived_from = @shard_derived_from
      if cached && (derived_from.nil? || persisted?)
        return cached
      end

      values = shard_key_values(config)
      return cached if cached && derived_from == values

      resolved = config.resolver.resolve(self)
      @shard_derived_from = values
      @current_shard = resolved
    end

    def save(*, validate : Bool = true, skip_timestamps : Bool = false, context : Symbol | Array(Symbol) | Nil = nil) : Bool
      within_own_shard do
        ensure_shard_key_unchanged!
        super
      end
    end

    def save!(*, validate : Bool = true, skip_timestamps : Bool = false, context : Symbol | Array(Symbol) | Nil = nil) : Bool
      within_own_shard do
        ensure_shard_key_unchanged!
        super
      end
    end

    def update_columns(**args) : Bool
      within_own_shard do
        ensure_shard_key_not_written!(args.keys.map(&.to_s))
        super
      end
    end

    def update_columns(args : Grant::ModelArgs) : Bool
      within_own_shard do
        ensure_shard_key_not_written!(args.keys.map(&.to_s))
        super
      end
    end

    def update_column(name : Symbol | String, value : Grant::Columns::Type) : Bool
      within_own_shard do
        ensure_shard_key_not_written!([name.to_s])
        super
      end
    end

    def delete : self
      within_own_shard { super }
    end

    def destroy : Bool
      within_own_shard { super }
    end

    def destroy! : Bool
      within_own_shard { super }
    end

    def touch(*fields, time : Time = Grant::Timestamps.current_time) : Bool
      within_own_shard { super }
    end

    def increment!(field : Symbol | String, by = 1, touch : Bool | Symbol | Array(Symbol) = false) : self
      within_own_shard do
        ensure_shard_key_not_written!([field.to_s])
        super
      end
    end

    def toggle!(field : Symbol | String) : self
      within_own_shard do
        ensure_shard_key_not_written!([field.to_s])
        super
      end
    end

    def reload
      within_own_shard { super }
    end

    # Runs the block with this record's shard active, so its statements reach
    # the shard the row lives on without the caller wrapping them in
    # `ShardManager.with_shard`. A record with no shard-key value yet uses the
    # shard the caller made active, if any.
    private def within_own_shard(&)
      return yield unless self.class.sharding_config

      shard = begin
        determine_shard
      rescue error : ShardKeyMissingError | ShardNotFoundError
        Grant::ShardManager.current_shard || raise error
      end

      Grant::ShardManager.with_shard(shard) { yield }
    end

    private def shard_key_values(config : ShardConfig) : Array(Grant::Columns::Type)
      config.key_column_names.map { |name| read_attribute(name) }
    end

    private def ensure_shard_key_unchanged! : Nil
      return unless persisted?
      config = self.class.sharding_config || return

      changed = changed_attribute_names_to_save & config.key_column_names
      raise_shard_key_changed(changed) unless changed.empty?
    end

    private def ensure_shard_key_not_written!(names : Array(String)) : Nil
      return unless persisted?
      config = self.class.sharding_config || return

      written = names & config.key_column_names
      raise_shard_key_changed(written) unless written.empty?
    end

    private def raise_shard_key_changed(columns : Array(String)) : NoReturn
      raise ShardKeyChangedError.new(
        "#{self.class.name} #{primary_key_value.inspect} lives on shard #{@current_shard.inspect}; " \
        "its shard key #{columns.join(", ")} cannot change in place. Use move_to_shard to relocate the record."
      )
    end
  end

  class ShardedQueryBuilder(Model)
    # Guards every join: the joined table must be stored on the same shards,
    # by the same shard key, as this relation's rows. Raw join fragments are
    # trusted as written.
    protected def add_join_clause(clause : Grant::Query::JoinSupport::Clause) : Nil
      ensure_colocated!(clause[:table]) unless clause[:type] == :raw
      super
    end

    private def ensure_colocated!(joined_table : String) : Nil
      table = joined_table.split(" AS ").first.strip
      own_config = Model.sharding_config || return

      target = model_for_table(table)
      target_config = target ? Grant::ShardManager.shard_config(target.name) : nil
      return if target_config && Grant::Sharding.colocated?(own_config, target_config)

      reason = if target.nil?
                 "#{table} is not reachable through an association of #{Model.name}, so its placement is unknown"
               elsif target_config.nil?
                 "#{target.name} is not sharded"
               else
                 "#{target.name} does not share the shard key #{own_config.key_column_names.join(", ")} and resolver of #{Model.name}"
               end
      raise CrossShardJoinError.new("Cannot join #{Model.name} to #{table}: #{reason}. Each shard is a separate database, so the join would miss rows on other shards.")
    end

    # The model stored in *table*, found by walking the associations reachable
    # from this relation's model.
    private def model_for_table(table : String) : (Grant::Base.class)?
      seen = Set(String).new
      queue = [Model] of Grant::Base.class
      until queue.empty?
        owner = queue.shift
        next unless seen.add?(owner.name)
        return owner if owner.table_name == table

        Grant::AssociationRegistry.reflections_for(owner.name).each do |reflection|
          if meta = Grant::AssociationRegistry.get(owner.name, reflection.name)
            queue << meta[:target_class]
          end
        end
      end
      nil
    end
  end
end
