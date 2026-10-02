class Grant::AssociationLoader
  # Preloads a `:through` association that cannot use the plain two-hop form:
  # a through of a through, a through whose source is itself a through, or a
  # polymorphic source read with `source_type:`. The through association is
  # loaded by its own loader (one IN query per hop, however deep); the targets
  # then cost one more IN query, or none when the source loads them itself.
  # Never a query per record.
  #
  # With *target_loader* the join rows' *join_target_key* is matched to the
  # targets' *target_key*; a polymorphic source passes *type_column* and
  # *type_value* so only join rows of the `source_type` class are followed.
  # Without one, the source association of the join rows is loaded and read.
  #
  # Like the lazy reader, every record gets each target once.
  #
  # :nodoc:
  def self.preload_nested_through(records : Array(Grant::Base), name : String,
                                  through_name : String, source_name : String, collection : Bool,
                                  target_loader : Proc(Array(Grant::Columns::Type), Array(Grant::Base))? = nil, join_target_key : String = "",
                                  target_key : String = "", type_column : String? = nil,
                                  type_value : String? = nil) : Nil
    load_named_association(records, through_name)
    join_rows_of = records.map { |record| rows_in(record.get_loaded_association(through_name)) }

    targets_by_key = {} of Grant::Columns::Type => Array(Grant::Base)
    if loader = target_loader
      followed = join_rows_of.flat_map(&.itself).select { |row| follows_type?(row, type_column, type_value) }
      target_values = key_values(followed, join_target_key)
      targets = target_values.empty? ? [] of Grant::Base : loader.call(target_values)
      targets.each do |target|
        (targets_by_key[target.read_attribute(target_key)] ||= [] of Grant::Base) << target
      end
    else
      all_rows = join_rows_of.flat_map(&.itself)
      all_rows.group_by(&.class).each_value { |group| load_named_association(group, source_name) }
    end

    records.each_with_index do |record, position|
      associated = [] of Grant::Base
      seen = Set(Grant::Columns::Type).new
      join_rows_of[position].each do |row|
        found = if target_loader
                  if follows_type?(row, type_column, type_value) && (key = row.read_attribute(join_target_key))
                    targets_by_key[key]? || [] of Grant::Base
                  else
                    [] of Grant::Base
                  end
                else
                  rows_in(row.get_loaded_association(source_name))
                end
        found.each do |target|
          identity = Grant::Polymorphic.primary_key_of(target)
          next if !identity.nil? && !seen.add?(identity)
          associated << target
        end
      end
      if collection
        record.set_loaded_association(name, associated)
        associated.each { |target| record._adopt_strict_loading(target, true) }
      else
        target = associated.first?
        record.set_loaded_association(name, target)
        record._adopt_strict_loading(target, false)
      end
    end
  end

  # Loads the association *name* on the records that do not have it yet, per
  # class, with the loader each model generates.
  private def self.load_named_association(records : Array(Grant::Base), name : String) : Nil
    records.group_by(&.class).each_value do |group|
      pending = group.reject(&.association_loaded?(name))
      next if pending.empty?
      unless batch_load(pending, name)
        raise Grant::AssociationNotFoundError.new(pending.first.class.name, name)
      end
    end
  end

  private def self.rows_in(value : Array(Grant::Base) | Grant::Base | Nil) : Array(Grant::Base)
    case value
    when Array(Grant::Base) then value
    when Grant::Base        then [value] of Grant::Base
    else                         [] of Grant::Base
    end
  end

  private def self.follows_type?(row : Grant::Base, type_column : String?, type_value : String?) : Bool
    return true unless type_column
    row.read_attribute(type_column) == type_value
  end
end
