require "./builder"

class Grant::Query::Builder(Model)
  # Loads the relation with *association* preloaded (one extra query, no N+1)
  # and returns the associated records: a `belongs_to`/`has_one` contributes its
  # target, a `has_many` its members. Records are flattened and made unique by
  # primary key, in the order first met.
  #
  # ```
  # Post.where(published: true).extract_associated(:author) # => [#<Author ...>, ...]
  # ```
  def extract_associated(association : Symbol) : Array(Grant::Base)
    loaded = preload(association).select
    seen = Set({String, Grant::Columns::Type}).new
    extracted = [] of Grant::Base
    loaded.each do |record|
      data = record.get_loaded_association(association)
      members = case data
                when Array(Grant::Base) then data
                when Grant::Base        then [data]
                else                         [] of Grant::Base
                end
      members.each do |member|
        primary_name = member.class.primary_name
        # A record without a primary key cannot be de-duplicated; keep each one.
        identity = primary_name ? member.read_attribute(primary_name) : member.object_id.to_i64
        key = {member.class.name, identity}
        next if seen.includes?(key)
        seen << key
        extracted << member
      end
    end
    extracted
  end
end
