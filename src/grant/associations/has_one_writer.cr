module Grant::Associations
  # The write behind `owner.profile = child` for a saved owner, as in
  # ActiveRecord's `HasOneAssociation#replace`: inside one transaction the
  # previous child is displaced by the association's `dependent:` strategy
  # (`:destroy` destroys it, `:delete` deletes it, anything else clears its
  # foreign key with one UPDATE) and the new child is pointed at the owner and
  # saved. When the save fails the transaction rolls back and
  # `Grant::RecordNotSaved` is raised, leaving the previous child in place.
  #
  # :nodoc:
  module HasOneWriter
    def self.replace(owner : Grant::Base, association_name : String, current : Grant::Base?, child : Grant::Base?, foreign_key : String, owner_key : Grant::Columns::Type, dependent : Symbol?, type_column : String? = nil, type_value : String? = nil) : Nil
      assigning_another = !same_record?(current, child)
      return if child && !assigning_another && !child.changed? && child.persisted?
      return if child.nil? && current.nil?

      owner.class.transaction do
        if current && assigning_another && !current.destroyed?
          displace(current, foreign_key, dependent, type_column)
        end
        if child
          child.set_attributes({foreign_key => owner_key})
          child.set_attributes({type_column => type_value}) if type_column && type_value
          unless child.save
            child.set_attributes({foreign_key => nil})
            child.set_attributes({type_column => nil}) if type_column
            raise Grant::RecordNotSaved.new(child.class.name, child)
          end
        end
      end
    end

    private def self.same_record?(first : Grant::Base?, second : Grant::Base?) : Bool
      return first.nil? && second.nil? if first.nil? || second.nil?
      return true if first.same?(second)

      first.class == second.class && first.persisted? && second.persisted? && first.primary_key_value == second.primary_key_value
    end

    private def self.displace(record : Grant::Base, foreign_key : String, dependent : Symbol?, type_column : String?) : Nil
      case dependent
      when :destroy, :destroy_async
        record.destroy
      when :delete
        record.delete
      else
        return unless record.persisted?

        assignments = [{foreign_key, nil.as(Grant::Columns::Type)}]
        assignments << {type_column, nil.as(Grant::Columns::Type)} if type_column
        record.class.where(record.class.primary_name, :eq, record.primary_key_value.as(Grant::Columns::Type))
          .update_all(assignments)
        assignments.each { |column, value| record.set_attributes({column => value}) }
      end
    end
  end
end
