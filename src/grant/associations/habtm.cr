module Grant::Associations
  # Declares a many-to-many association over a bare join table, the way
  # ActiveRecord's `has_and_belongs_to_many` does. The macro defines a hidden
  # join model (`Post::HABTM_Tags`) mapped to the join table and expands to a
  # `has_many :through` on it, so the writers (`<<`, `delete`, `build`,
  # `create`, `<singular>_ids=`, `clear`) are the through writers.
  #
  # The join table is named from the two table names in lexical order
  # (`posts_tags`) and has one foreign key column per side; it needs no primary
  # key column of its own. Declare the macro after `connection`, because the hidden join model
  # uses the owner's connection.
  #
  # Options:
  #
  # * `class_name:` — the target class when it differs from the inferred name.
  # * `join_table:` — the join table name.
  # * `foreign_key:` — the join column that points at this model
  #   (default `"<this_model>_id"`).
  # * `association_foreign_key:` — the join column that points at the target
  #   (default `"<singular>_id"`).
  # * `singular:` — the singular stem for `<singular>_ids` and the target
  #   `belongs_to` on the join model when the built-in singularizer is wrong.
  # * `before_add:` / `after_add:` / `before_remove:` / `after_remove:` — see
  #   `has_many`.
  #
  # Join columns are declared as `Int64`. Destroying the owner deletes its
  # join rows.
  #
  # ```
  # class Post < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   has_and_belongs_to_many :tags
  # end
  #
  # class Tag < Grant::Base
  #   connection sqlite
  #   column id : Int64, primary: true
  #   has_and_belongs_to_many :posts
  # end
  #
  # post.tags << Tag.create!(name: "crystal") # one INSERT into posts_tags
  # post.tag_ids = [1, 2]                     # diff applied set-based
  # ```
  macro has_and_belongs_to_many(name, **options)
    {% owner = @type %}
    {% association = name.id.stringify %}
    {% if options[:singular] %}
      {% singular = options[:singular].id.stringify %}
    {% elsif association.ends_with?("ies") %}
      {% singular = association[0...-3] + "y" %}
    {% elsif association.ends_with?("ses") || association.ends_with?("xes") || association.ends_with?("zes") || association.ends_with?("ches") || association.ends_with?("shes") %}
      {% singular = association[0...-2] %}
    {% elsif association.ends_with?("s") && !association.ends_with?("ss") %}
      {% singular = association[0...-1] %}
    {% else %}
      {% singular = association %}
    {% end %}
    {% class_name = options[:class_name] || singular.camelcase %}
    {% owner_key = (options[:foreign_key] || (owner.stringify.split("::").last.underscore + "_id")).id.stringify %}
    {% target_key = (options[:association_foreign_key] || (singular + "_id")).id.stringify %}
    {% join_class = "HABTM_" + association.camelcase %}
    {% join_association = "habtm_join_" + association %}

    # The hidden join model. It maps the join table on the owner's connection.
    class {{join_class.id}} < Grant::Base
      self.database_name = ::{{owner}}.database_name

      def self.table_name : String
        {% if options[:join_table] %}
          {{options[:join_table].id.stringify}}
        {% else %}
          [::{{owner}}.table_name, ::{{class_name.id}}.table_name].sort!.join("_")
        {% end %}
      end

      # A join row is identified by its two keys. The composite key gives the
      # model the primary key the query layer expects; the join table itself
      # needs no key column.
      include Grant::CompositePrimaryKey

      column {{owner_key.id}} : Int64, primary: true, auto: false
      column {{target_key.id}} : Int64, primary: true, auto: false
      composite_primary_key {{owner_key.id}}, {{target_key.id}}

      belongs_to {{singular.id}}, class_name: {{class_name.id}}, foreign_key: :{{target_key.id}}, optional: true
    end

    has_many {{join_association.id}}, class_name: ::{{owner}}::{{join_class.id}}, foreign_key: :{{owner_key.id}}, dependent: :delete_all
    has_many {{name}}, class_name: {{class_name.id}}, through: :{{join_association.id}}, source: :{{singular.id}}, singular: :{{singular.id}}{% for key, value in options %}{% unless ["class_name", "join_table", "foreign_key", "association_foreign_key", "singular"].includes?(key.stringify) %}, {{key.id}}: {{value}}{% end %}{% end %}
  end
end
