module Grant::Autosave::AssociationOperations
  def self.loaded_record(owner : Grant::Base, name : String) : Grant::Base?
    return unless owner.association_loaded?(name)

    owner.get_loaded_association(name).as?(Grant::Base)
  end

  def self.each_unique_record(owner : Grant::Base, name : String, consume : Proc(Grant::Base, Nil)) : Nil
    seen = Set(UInt64).new
    if owner.association_loaded?(name) && (loaded = owner.get_loaded_association(name).as?(Array(Grant::Base)))
      loaded.each do |candidate|
        consume.call(candidate) if seen.add?(candidate.object_id)
      end
    end
    owner._autosave_staged(name).each do |candidate|
      consume.call(candidate) if seen.add?(candidate.object_id)
    end
  end

  def self.validate_many(owner : Grant::Base, name : String, foreign_key : String, records : Array(Grant::Base), autosaving : Bool, indexed : Bool) : Nil
    candidates = records.select do |record|
      if owner.new_record?
        true
      elsif autosaving
        record.changed_for_autosave?
      else
        record.new_record?
      end
    end

    candidates.each_with_index do |record, position|
      next if record.destroyed? || (autosaving && record.marked_for_destruction?)
      record._grant_skip_nested_owner_foreign_key_validation(foreign_key) if owner.new_record?
      next if record.valid?

      if autosaving
        owner._autosave_import_errors(name, record, indexed ? position : nil)
      else
        owner.errors.add(name, "is invalid", :invalid)
      end
    end
  end

  def self.validate_one(owner : Grant::Base, name : String, association_type : Symbol, foreign_key : String, record : Grant::Base?, autosaving : Bool) : Nil
    return unless record
    return unless record.changed_for_autosave? && !record.destroyed? && !(autosaving && record.marked_for_destruction?)

    record._grant_skip_nested_owner_foreign_key_validation(foreign_key) if association_type == :has_one && owner.new_record?
    return if record.valid?

    if autosaving
      owner._autosave_import_errors(name, record, nil)
    else
      owner.errors.add(name, "is invalid", :invalid)
    end
  end

  def self.import_errors(owner : Grant::Base, association : String, record : Grant::Base, index : Int32?) : Nil
    prefix = index ? "#{association}[#{index}]" : association
    record.errors.each do |error|
      options = error.options? ? error.options.dup : nil
      owner.errors << Grant::Error.new("#{prefix}.#{error.field}", error.message, error.type, options: options, base: owner)
    end
  end
end
