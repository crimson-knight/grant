require "./composite_association"
require "./composite_collection"

# Associations whose foreign key spans several columns.
#
# `foreign_key:` (or ActiveRecord's `query_constraints:`) takes a tuple of
# column names, in the order of the parent key it references. `primary_key:`
# names the referenced columns and defaults to the parent's composite primary
# key (or its `query_constraints`):
#
# ```
# class Order < Grant::Base
#   include Grant::CompositePrimaryKey
#   column shop_id : Int64, primary: true, auto: false
#   column id : Int64, primary: true, auto: false
#   composite_primary_key shop_id, id
#   has_many :items, class_name: OrderItem, foreign_key: {:shop_id, :order_id}
# end
#
# class OrderItem < Grant::Base
#   column id : Int64, primary: true
#   column shop_id : Int64
#   column order_id : Int64
#   belongs_to :order, class_name: Order, foreign_key: {:shop_id, :order_id}
# end
#
# order.items                 # one query, (shop_id, order_id) = (?, ?)
# Order.includes(:items).to_a # one query for all orders: (shop_id, order_id) IN (...)
# ```
#
# The foreign key columns are not created for you (declare them with
# `column`). Supported: `belongs_to`, `has_one` and `has_many` with
# `class_name:`, `primary_key:`, `inverse_of:`, `strict_loading:`, a scope, and
# `dependent: :destroy | :delete_all | :delete | :nullify` (has_many, has_one).
# Not supported, and a compile error when given: `through:`, `as:`,
# `polymorphic:`, `counter_cache:`, `touch:`.
module Grant::Associations
  # :nodoc:
  macro __composite_key_names(value)
    [{% for column in value %}{{column.id.stringify}}, {% end %}] of String
  end

  # :nodoc:
  macro __composite_scope_proc(scope, class_name)
    {% if scope %}
      {% if scope.args.empty? %}
        ->(query : Grant::Query::Builder({{class_name.id}})) { query.{{scope.body}} }
      {% else %}
        {{scope}}
      {% end %}
    {% else %}
      nil.as(Proc(Grant::Query::Builder({{class_name.id}}), Grant::Query::Builder({{class_name.id}}))?)
    {% end %}
  end

  # :nodoc:
  macro __composite_check_options(kind, options)
    {% for unsupported in [:through, :as, :polymorphic, :counter_cache, :touch, :autosave] %}
      {% if options[unsupported] %}
        {% raise "#{kind} with a composite foreign key does not support `#{unsupported.id}:`" %}
      {% end %}
    {% end %}
  end

  # Declares the `belongs_to` side of a composite foreign key. See the module
  # documentation; reached through `belongs_to ..., foreign_key: {:a, :b}`.
  macro composite_belongs_to(model, scope = nil, **options)
    {% if model.is_a?(TypeDeclaration) %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase %}
    {% end %}
    {% foreign_key = options[:foreign_key] || options[:query_constraints] %}
    {% primary_key = options[:primary_key] %}
    {% name_text = method_name.stringify %}
    {% inverse_of = options[:inverse_of] %}
    Grant::Associations.__composite_check_options("belongs_to", {{options}})

    @[Grant::Relationship(target: {{class_name.id}}, type: :belongs_to, composite: true,
      foreign_key: {{foreign_key.map(&.id.stringify).join(",")}},
      primary_key: {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, scope: {{scope}})]
    def {{method_name}} : {{class_name.id}}?
      if association_loaded?({{name_text}})
        get_loaded_association({{name_text}}).as({{class_name.id}}?)
      else
        assert_association_can_lazy_load!({{name_text}}, {{options[:strict_loading]}})
        parent = Grant::CompositeAssociation.find_one(
          self, {{class_name.id}}, Grant::Associations.__composite_key_names({{foreign_key}}),
          {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{class_name.id}}){% end %},
          Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}}))
        if parent
          Grant::Logs::Association.debug { "Loaded belongs_to association - #{self.class.name}.#{{{name_text}}} [#{{{class_name.id.stringify}}}] [composite key]" }
          _adopt_strict_loading(parent, false)
          {% if inverse_of %}
            parent.set_loaded_association({{inverse_of.id.stringify}}, self)
          {% end %}
        end
        parent
      end
    end

    def {{method_name}}! : {{class_name.id}}
      {{method_name}} || raise Grant::Querying::NotFound.new("No {{class_name.id}} found for composite key (#{Grant::Associations.__composite_key_names({{foreign_key}}).join(", ")})")
    end

    # Copies the parent's key columns into the foreign key columns (or clears
    # them for `nil`) and caches the parent.
    def {{method_name}}=(parent : {{class_name.id}}?)
      Grant::CompositeAssociation.assign_belongs_to(
        self, parent, Grant::Associations.__composite_key_names({{foreign_key}}),
        {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{class_name.id}}){% end %})
      set_loaded_association({{name_text}}, parent)
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{name_text}})
    end

    def reload_{{method_name.id}} : {{class_name.id}}?
      reload_association({{name_text}})
      {{method_name}}
    end

    # The composite preload run by `includes(:{{method_name}})`: one query for
    # the whole batch of records, keyed by the key tuple.
    def __composite_preload_{{method_name.id}}(records : Array(Grant::Base), restriction : Array(Grant::Query::WhereField)?) : Nil
      Grant::CompositeAssociation.preload_belongs_to(
        records, {{name_text}}, Grant::Associations.__composite_key_names({{foreign_key}}),
        {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{class_name.id}}){% end %},
        ->(tuples : Array(Array(Grant::Columns::Type))) : Array(Grant::Base) {
          relation = {{class_name.id}}.current_scope
          scope_proc = Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}})
          relation = scope_proc.call(relation) if scope_proc
          restriction.try(&.each { |condition| relation.own_where_fields << condition })
          relation.where_tuples!(
            {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{class_name.id}}){% end %},
            tuples).select.map(&.as(Grant::Base))
        })
    end

    _grant_register_association({{method_name.id.stringify}}, :belongs_to, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, nil)
    _grant_register_reflection({{method_name.id.stringify}}, :belongs_to, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}},
      nil, nil, nil, nil, nil, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)
  end

  # Declares the `has_many` side of a composite foreign key. See the module
  # documentation; reached through `has_many ..., foreign_key: {:a, :b}`.
  macro composite_has_many(model, scope = nil, **options)
    {% if model.is_a?(TypeDeclaration) %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase.gsub(/ies$/, "y").gsub(/s$/, "") %}
    {% end %}
    {% foreign_key = options[:foreign_key] || options[:query_constraints] %}
    {% primary_key = options[:primary_key] %}
    {% name_text = method_name.stringify %}
    {% inverse_of = options[:inverse_of] %}
    Grant::Associations.__composite_check_options("has_many", {{options}})

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_many, composite: true,
      foreign_key: {{foreign_key.map(&.id.stringify).join(",")}},
      primary_key: {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, scope: {{scope}})]
    def {{method_name}} : Grant::CompositeCollection({{@type}}, {{class_name.id}})
      loaded_records = nil.as(Array({{class_name.id}})?)
      if association_loaded?({{name_text}})
        loaded_data = get_loaded_association({{name_text}})
        loaded_records = loaded_data.map(&.as({{class_name.id}})) if loaded_data.is_a?(Array(Grant::Base))
      end
      Grant::CompositeCollection({{@type}}, {{class_name.id}}).new(
        self, {{name_text}}, Grant::Associations.__composite_key_names({{foreign_key}}),
        {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %},
        Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}}),
        loaded_records, {{options[:strict_loading]}}, {{inverse_of ? inverse_of.id.stringify : nil}})
    end

    # Replaces the cached collection, pointing each record at this owner.
    def {{method_name}}=(records : Array({{class_name.id}}))
      owner_values = Grant::CompositeAssociation.owner_key_values(
        self, {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %})
      if owner_values
        records.each do |record|
          Grant::CompositeAssociation.assign_key(record, Grant::Associations.__composite_key_names({{foreign_key}}), owner_values)
        end
      end
      set_loaded_association({{name_text}}, records.map(&.as(Grant::Base)))
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{name_text}})
    end

    def reload_{{method_name.id}} : Grant::CompositeCollection({{@type}}, {{class_name.id}})
      reload_association({{name_text}})
      {{method_name}}
    end

    def __composite_preload_{{method_name.id}}(records : Array(Grant::Base), restriction : Array(Grant::Query::WhereField)?) : Nil
      Grant::CompositeAssociation.preload_has(
        records, {{name_text}}, Grant::Associations.__composite_key_names({{foreign_key}}),
        {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %},
        ->(tuples : Array(Array(Grant::Columns::Type))) : Array(Grant::Base) {
          relation = {{class_name.id}}.current_scope
          scope_proc = Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}})
          relation = scope_proc.call(relation) if scope_proc
          restriction.try(&.each { |condition| relation.own_where_fields << condition })
          relation.where_tuples!(Grant::Associations.__composite_key_names({{foreign_key}}), tuples).select.map(&.as(Grant::Base))
        }, true)
    end

    _grant_register_association({{method_name.id.stringify}}, :has_many, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, nil)
    _grant_register_reflection({{method_name.id.stringify}}, :has_many, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}},
      nil, nil, nil, nil, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    __composite_dependent({{method_name}}, :has_many, {{class_name}}, {{options[:dependent]}}, {{foreign_key}}, {{primary_key}})
  end

  # Declares the `has_one` side of a composite foreign key. See the module
  # documentation; reached through `has_one ..., foreign_key: {:a, :b}`.
  macro composite_has_one(model, scope = nil, **options)
    {% if model.is_a?(TypeDeclaration) %}
      {% method_name = model.var %}
      {% class_name = model.type %}
    {% else %}
      {% method_name = model.id %}
      {% class_name = options[:class_name] || model.id.camelcase %}
    {% end %}
    {% foreign_key = options[:foreign_key] || options[:query_constraints] %}
    {% primary_key = options[:primary_key] %}
    {% name_text = method_name.stringify %}
    {% inverse_of = options[:inverse_of] %}
    Grant::Associations.__composite_check_options("has_one", {{options}})

    @[Grant::Relationship(target: {{class_name.id}}, type: :has_one, composite: true,
      foreign_key: {{foreign_key.map(&.id.stringify).join(",")}},
      primary_key: {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, scope: {{scope}})]
    def {{method_name}} : {{class_name.id}}?
      if association_loaded?({{name_text}})
        get_loaded_association({{name_text}}).as({{class_name.id}}?)
      else
        assert_association_can_lazy_load!({{name_text}}, {{options[:strict_loading]}})
        child = Grant::CompositeAssociation.find_child(
          self, {{class_name.id}}, Grant::Associations.__composite_key_names({{foreign_key}}),
          {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %},
          Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}}))
        set_loaded_association({{name_text}}, child)
        if child
          _adopt_strict_loading(child, false)
          {% if inverse_of %}
            child.set_loaded_association({{inverse_of.id.stringify}}, self)
          {% end %}
        end
        child
      end
    end

    def {{method_name}}! : {{class_name.id}}
      {{method_name}} || raise Grant::Querying::NotFound.new("No {{class_name.id}} found for composite key (#{Grant::Associations.__composite_key_names({{foreign_key}}).join(", ")})")
    end

    # Points *child* at this owner (in memory; save the child to persist).
    def {{method_name}}=(child : {{class_name.id}}?)
      if child
        owner_values = Grant::CompositeAssociation.owner_key_values(
          self, {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %})
        if owner_values
          Grant::CompositeAssociation.assign_key(child, Grant::Associations.__composite_key_names({{foreign_key}}), owner_values)
        end
      end
      set_loaded_association({{name_text}}, child)
    end

    def reset_{{method_name.id}} : Nil
      reset_association({{name_text}})
    end

    def reload_{{method_name.id}} : {{class_name.id}}?
      reload_association({{name_text}})
      {{method_name}}
    end

    def __composite_preload_{{method_name.id}}(records : Array(Grant::Base), restriction : Array(Grant::Query::WhereField)?) : Nil
      Grant::CompositeAssociation.preload_has(
        records, {{name_text}}, Grant::Associations.__composite_key_names({{foreign_key}}),
        {% if primary_key %}Grant::Associations.__composite_key_names({{primary_key}}){% else %}Grant::CompositeAssociation.key_columns_of({{@type}}){% end %},
        ->(tuples : Array(Array(Grant::Columns::Type))) : Array(Grant::Base) {
          relation = {{class_name.id}}.current_scope
          scope_proc = Grant::Associations.__composite_scope_proc({{scope}}, {{class_name}})
          relation = scope_proc.call(relation) if scope_proc
          Grant::CompositeAssociation.order_by_key(relation) if relation.order_fields.empty?
          restriction.try(&.each { |condition| relation.own_where_fields << condition })
          relation.where_tuples!(Grant::Associations.__composite_key_names({{foreign_key}}), tuples).select.map(&.as(Grant::Base))
        }, false)
    end

    _grant_register_association({{method_name.id.stringify}}, :has_one, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}}, nil)
    _grant_register_reflection({{method_name.id.stringify}}, :has_one, {{class_name.id}},
      {{foreign_key.map(&.id.stringify).join(",")}}, {{primary_key ? primary_key.map(&.id.stringify).join(",") : ""}},
      nil, nil, nil, nil, {{options[:dependent]}}, {{inverse_of ? inverse_of.id.stringify : nil}}, {{options[:inverse_of] == false}},
      {{scope ? true : false}}, false, {{options[:strict_loading]}}, {{options.keys.map(&.stringify)}} of String, {{options.values.map(&.stringify)}} of String)

    __composite_dependent({{method_name}}, :has_one, {{class_name}}, {{options[:dependent]}}, {{foreign_key}}, {{primary_key}})
  end

  # `dependent:` for composite has_many and has_one: the dependents are found
  # by the whole foreign key tuple.
  #
  # :nodoc:
  macro __composite_dependent(name, kind, class_name, strategy, foreign_key, primary_key)
    {% if strategy %}
      {% unless [:destroy, :delete_all, :delete, :nullify].includes?(strategy) %}
        {% raise "composite #{kind} supports dependent: :destroy, :delete_all, :delete or :nullify, got #{strategy}" %}
      {% end %}
      {% owner_keys = primary_key ? "Grant::Associations.__composite_key_names(#{primary_key})".id : "Grant::CompositeAssociation.key_columns_of(#{@type})".id %}
      {% if strategy == :destroy %}
        around_destroy do
          self.class.transaction do
            block.call
          end
        end
        before_destroy do
          reflection = Grant::AssociationRegistry.reflection({{@type.name.stringify}}, {{name.id.stringify}})
          Grant::CompositeAssociation.dependents_of(self, {{class_name.id}}, Grant::Associations.__composite_key_names({{foreign_key}}), {{owner_keys}}).each do |record|
            record.destroyed_by_association = reflection
            abort!("Failed to destroy dependent {{name.id}}") unless record.destroy
          end
        end
      {% elsif strategy == :nullify %}
        after_destroy do
          Grant::CompositeAssociation.nullify_dependents(self, {{class_name.id}}, Grant::Associations.__composite_key_names({{foreign_key}}), {{owner_keys}})
        end
      {% else %}
        before_destroy do
          Grant::CompositeAssociation.delete_dependents(self, {{class_name.id}}, Grant::Associations.__composite_key_names({{foreign_key}}), {{owner_keys}})
        end
      {% end %}
    {% end %}
  end
end
