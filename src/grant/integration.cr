module Grant
  # Keys for routes and caches: `to_key`, `to_param`, `cache_key`,
  # `cache_version` and `cache_key_with_version`, plus the `to_param :column`
  # override.
  #
  # ```
  # user = User.find!(1)
  # user.to_param               # => "1"
  # user.cache_key              # => "users/1"
  # user.cache_version          # => "20260928120000123456"
  # user.cache_key_with_version # => "users/1-20260928120000123456"
  # ```
  #
  # Nothing here queries the database: the version comes from the in-memory
  # `updated_at`.
  module Integration
    module ClassMethods
      # A key for the relation of all rows, `"users/query-<digest>-<count>-<newest updated_at>"`.
      # One aggregate query (COUNT and MAX(updated_at)), no records loaded.
      def collection_cache_key : String
        current_scope.collection_cache_key
      end
    end

    # Overrides `to_param` to use *attribute* (for example a slug) instead of the
    # primary key. New records still return nil.
    #
    # ```
    # class Post < Grant::Base
    #   to_param :slug
    # end
    # ```
    macro to_param(attribute)
      def to_param : String?
        return nil unless persisted?
        value = self.{{attribute.id}}?
        value.nil? ? nil : value.to_s
      end
    end

    # The primary key values as an array, or nil while any is unset.
    def to_key : Array(Grant::Columns::Type)?
      values = primary_key_values.values
      return if values.empty? || values.any?(Nil)
      values
    end

    # The key for URLs: the primary key values joined with `-`, or nil for a
    # record that is not persisted.
    def to_param : String?
      return unless persisted?
      key = to_key
      key ? key.join('-') : nil
    end

    # `"users/1"`, or `"users/new"` before the record is saved.
    def cache_key : String
      key = to_key
      if new_record? || key.nil?
        "#{self.class.table_name}/new"
      else
        "#{self.class.table_name}/#{key.join('-')}"
      end
    end

    # A stamp of the in-memory `updated_at` in UTC (`%Y%m%d%H%M%S%6N`), or nil
    # when the model has no `updated_at` column or it is unset. Never queries.
    def cache_version : String?
      {% if @type.instance_vars.any? { |ivar| ivar.annotation(Grant::Column) && ivar.name.stringify == "updated_at" } %}
        stamp = @updated_at
        if stamp.is_a?(Time)
          stamp.to_utc.to_s("%Y%m%d%H%M%S%6N")
        end
      {% else %}
        nil
      {% end %}
    end

    # `cache_key` followed by `-` and the `cache_version`, when there is one.
    def cache_key_with_version : String
      version = cache_version
      version ? "#{cache_key}-#{version}" : cache_key
    end
  end
end

class Grant::Query::Builder(Model)
  # A key for the relation's current contents:
  # `"users/query-<digest>-<count>-<newest updated_at>"`. Issues one aggregate
  # query (COUNT and MAX(updated_at)) and never loads records.
  #
  # ```
  # User.where(active: true).collection_cache_key
  # ```
  def collection_cache_key : String
    "#{cache_key}-#{cache_version}"
  end
end

class Grant::Query::Builder(Model)
  # The column *name* stands for once the model's `alias_attribute`s are
  # applied. Query-builder specs use plain stand-in models without aliases.
  private def resolve_column_alias(name : String) : String
    {% if Model.class.has_method?(:resolve_attribute_alias) %}
      Model.resolve_attribute_alias(name)
    {% else %}
      name
    {% end %}
  end
end
