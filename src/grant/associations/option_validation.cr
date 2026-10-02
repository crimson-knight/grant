module Grant::Associations
  # Rejects an option the association macro does not understand, so a typo
  # such as `dependant: :destroy` or `foriegn_key:` fails the build instead of
  # being ignored. Runs while the macro expands, so it costs nothing at
  # runtime. `dependent:` values are checked by `Grant::Dependent`.
  #
  # Mirrors ActiveRecord's `Association.valid_options`, which raises
  # `ArgumentError` for an unknown key; here the error is a compile error.
  #
  # :nodoc:
  macro _grant_check_association_options(kind, model, keys, through, source_type)
    {%
      name = model.is_a?(TypeDeclaration) ? model.var : model.id
      common = %w[class_name foreign_key primary_key query_constraints inverse_of strict_loading autosave validate index_errors dependent]
      valid = if kind == :belongs_to
                common + %w[polymorphic type_column optional counter_cache touch default converter primary foreign_key_declared constraint]
              elsif kind == :has_one
                common + %w[through source source_type as type_column]
              else
                common + %w[through source source_type as type_column singular counter_cache before_add after_add before_remove after_remove]
              end
      keys.each do |key|
        unless valid.includes?(key)
          raise "Unknown option `#{key.id}:` for `#{kind.id} :#{name}` on #{@type}. Valid options: #{valid.sort.map { |option| "#{option.id}:" }.join(", ").id}."
        end
      end
      if source_type && !through
        raise "`source_type:` on `#{kind.id} :#{name}` in #{@type} needs `through:` (it names the class of a polymorphic source)."
      end
    %}
  end
end
