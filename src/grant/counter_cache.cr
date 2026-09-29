require "./counters"

# Counter caches: a `belongs_to ..., counter_cache:` keeps a count column on the
# parent in step with its children, and the class helpers below repair or adjust
# that column.
#
# ```
# class Post < Grant::Base
#   belongs_to :user, counter_cache: true # maintains User#posts_count
# end
#
# User.reset_counters(user.id, :posts)    # recount with one UPDATE
# User.increment_counter(:posts_count, 1) # atomic col = col + 1
# User.decrement_counter(:posts_count, 1, by: 2)
# ```
module Grant::CounterCache
  # One `belongs_to` counter cache: the child model's association, the
  # parent's column, and whether Grant maintains it (`active: false` leaves the
  # column alone, for the time a counter is being introduced or repaired).
  record Entry,
    parent_class : String,
    child_class : String,
    association : String,
    foreign_key : String,
    column : String,
    active : Bool

  @@entries = [] of Entry
  @@mutex = Mutex.new

  # :nodoc:
  def self.register(entry : Entry) : Nil
    @@mutex.synchronize do
      updated = @@entries.reject do |existing|
        existing.child_class == entry.child_class && existing.association == entry.association
      end
      updated << entry
      @@entries = updated
    end
  end

  # The counter cache the *child_class* declared on the foreign key
  # *foreign_key* of *parent_class*, if any.
  def self.find(parent_class : String, child_class : String, foreign_key : String) : Entry?
    @@entries.find do |entry|
      entry.parent_class == parent_class && entry.child_class == child_class && entry.foreign_key == foreign_key
    end
  end

  # The maintained counter column for that association, or `nil` when there is
  # none or it is `active: false`.
  def self.active_column(parent_class : String, child_class : String, foreign_key : String) : String?
    entry = find(parent_class, child_class, foreign_key)
    entry.column if entry && entry.active
  end

  # The pluralized default column, e.g. `Category` gives `categories_count`.
  def self.default_column(child_class : String) : String
    "#{pluralize(child_class.split("::").last.underscore)}_count"
  end

  IRREGULAR_PLURALS = {
    "child"  => "children",
    "person" => "people",
    "man"    => "men",
    "woman"  => "women",
    "mouse"  => "mice",
    "goose"  => "geese",
    "tooth"  => "teeth",
    "foot"   => "feet",
    "quiz"   => "quizzes",
  }

  # Pluralizes the last word of a snake_case *name* with the same rules
  # `has_many` uses to singularize.
  def self.pluralize(name : String) : String
    words = name.split('_')
    last = words.pop
    words << plural_word(last)
    words.join('_')
  end

  private def self.plural_word(word : String) : String
    if irregular = IRREGULAR_PLURALS[word]?
      irregular
    elsif word.size > 1 && word.ends_with?('y') && !"aeiou".includes?(word[-2])
      word[0...-1] + "ies"
    elsif word.ends_with?("s") || word.ends_with?("x") || word.ends_with?("z") || word.ends_with?("ch") || word.ends_with?("sh")
      word + "es"
    else
      word + "s"
    end
  end

  # The instance side: adjusting a counter in memory without marking the
  # attribute changed, so a parent that is already loaded stays in step.
  module Instance
    # :nodoc:
    def __counter_adjust_in_memory(column : String, delta : Int64) : Nil
      return unless self.class.fields.includes?(column)
      current = read_attribute(column)
      was_changed = attribute_changed?(column)
      updated = case current
                when Int32 then current + delta.to_i32
                when Int64 then current + delta
                else            return
                end
      write_attribute(column, updated.as(Grant::Columns::Type))
      clear_dirty_tracking_for([column]) unless was_changed
    end
  end

  module ClassMethods
    # Recounts the counter cache of the association(s) *associations* for the
    # row with primary key *id*, with one correlated-subquery UPDATE per
    # association (`SET posts_count = (SELECT COUNT(*) FROM posts WHERE ...)`).
    # Nothing is loaded. Pass `touch:` to refresh timestamps as well. Returns the
    # number of rows updated.
    #
    # ```
    # User.reset_counters(1, :posts)
    # ```
    def reset_counters(id : Grant::Querying::IdValue, *associations : Symbol, touch : Bool | Symbol | Array(Symbol) = false) : Int64
      guard_writes!
      updated = 0_i64
      associations.each do |association|
        reflection = Grant::AssociationRegistry.reflection(name, association.to_s) ||
                     raise Grant::AssociationNotFoundError.new(name, association.to_s)
        unless reflection.macro == :has_many
          raise ArgumentError.new("#{name}##{association} is not a has_many association")
        end
        if reflection.through
          raise ArgumentError.new("reset_counters does not support the :through association #{name}##{association}")
        end
        column = __counter_column_for(reflection) ||
                 raise ArgumentError.new("#{name}##{association} has no counter cache; declare `counter_cache:` on the child's belongs_to")
        child_class = Grant::AssociationRegistry.model_class(reflection.class_name) ||
                      raise Grant::AssociationNotFoundError.new(name, association.to_s)
        child_table = child_class.table_name
        subquery = "(SELECT COUNT(*) FROM #{quote(child_table)} WHERE #{quote(child_table)}.#{adapter.quote(reflection.foreign_key)} = #{quoted_table_name}.#{quote(reflection.primary_key)})"
        relation = __counter_write_scope.where(primary_name, :eq, id.as(Grant::Columns::Type))
        mark_write_operation
        updated += relation.update_all("#{quote(column)} = #{subquery}").rows_affected
        case touch
        when true   then relation.touch_all
        when Symbol then relation.touch_all(touch)
        when Array  then touch.each { |column_name| relation.touch_all(column_name) }
        end
      end
      updated
    end

    # Adds *by* (default `1`) to *column* of the row with primary key *id* with
    # one atomic `col = col + n` UPDATE. Returns the number of rows changed.
    def increment_counter(column : Symbol | String, id : Grant::Querying::IdValue, by : Int32 = 1, touch : Bool | Symbol | Array(Symbol) = false) : Int64
      update_counters(id, {column => by}, touch)
    end

    # Subtracts *by* (default `1`) from *column*; see `increment_counter`.
    def decrement_counter(column : Symbol | String, id : Grant::Querying::IdValue, by : Int32 = 1, touch : Bool | Symbol | Array(Symbol) = false) : Int64
      update_counters(id, {column => -by}, touch)
    end

    # The relation counter writes go through: the tenant's rows for a
    # multitenant model, every row otherwise (default scopes never hide the
    # parent from its own counter).
    #
    # :nodoc:
    def __counter_write_scope
      __multitenant? ? __tenant_write_scope : unscoped
    end

    # :nodoc:
    def __counter_column_for(reflection : Grant::Reflection) : String?
      if option = reflection.options["counter_cache"]?
        option = option.strip(':').strip('"')
        return option == "true" ? "#{reflection.name}_count" : option
      end
      entry = Grant::CounterCache.find(name, reflection.class_name, reflection.foreign_key)
      entry.column if entry
    end
  end
end

module Grant::AssociationOptions
  # Implements the `counter_cache:` `belongs_to` option.
  module CounterCache
    # Keeps a counter column on the parent in sync with the number of children.
    # Emitted by `belongs_to ..., counter_cache:`: it increments on create,
    # decrements on destroy, and moves the count when the foreign key changes.
    # Every change is an atomic `col = col + n` UPDATE, and a parent that is
    # already loaded on the child has its in-memory count adjusted too.
    #
    # `counter_cache: true` names the column `<plural_model>_count` (`Category`
    # gives `categories_count`); a name overrides it. `counter_cache: {column:
    # :n, active: false}` records the counter for `reset_counters` and `size`
    # without maintaining it.
    #
    # ```
    # class Post < Grant::Base
    #   belongs_to :user, counter_cache: true # maintains User#posts_count
    # end
    # ```
    macro setup_counter_cache(association_name, model_class, counter_column, foreign_key, active = true)
      {% if counter_column.is_a?(NilLiteral) %}
        {% counter_column_name = nil %}
      {% elsif counter_column.is_a?(SymbolLiteral) || counter_column.is_a?(StringLiteral) %}
        {% counter_column_name = counter_column.id.stringify %}
      {% else %}
        {% counter_column_name = counter_column.stringify.gsub(/"/, "") %}
      {% end %}

      Grant::CounterCache.register(Grant::CounterCache::Entry.new(
        {{model_class.id}}.name, {{@type.name.stringify}}, {{association_name.id.stringify}}, {{foreign_key}},
        {% if counter_column_name %}{{counter_column_name}}{% else %}Grant::CounterCache.default_column({{@type.name.stringify}}){% end %},
        {{active ? true : false}}))

      {% if active %}
        private def _{{association_name.id}}_counter_column : String
          {% if counter_column_name %}{{counter_column_name}}{% else %}Grant::CounterCache.default_column({{@type.name.stringify}}){% end %}
        end

        private def _{{association_name.id}}_adjust_counter(parent_key, delta : Int64) : Nil
          return if parent_key.nil?
          column = _{{association_name.id}}_counter_column
          {{model_class.id}}.__apply_counter_update(
            {{model_class.id}}.__counter_write_scope.where({{model_class.id}}.primary_name, :eq, parent_key.as(Grant::Columns::Type)),
            {column => delta})
          if association_loaded?({{association_name.id.stringify}})
            if parent = get_loaded_association({{association_name.id.stringify}}).as?({{model_class.id}})
              parent.__counter_adjust_in_memory(column, delta) if parent.read_attribute({{model_class.id}}.primary_name) == parent_key
            end
          end
        end

        after_create do
          _{{association_name.id}}_adjust_counter(self.read_attribute({{foreign_key}}), 1_i64)
        end

        # A record destroyed by its parent's `dependent: :destroy` leaves the
        # parent's count alone: the parent is going away.
        after_destroy do
          by_parent = destroyed_by_association
          unless by_parent && by_parent.foreign_key == {{foreign_key}}
            _{{association_name.id}}_adjust_counter(self.read_attribute({{foreign_key}}), -1_i64)
          end
        end

        before_update do
          if attribute_changed?({{foreign_key}})
            old_key = attribute_was({{foreign_key}})
            _{{association_name.id}}_adjust_counter(old_key.as(Grant::Columns::Type), -1_i64) unless old_key.nil?
            _{{association_name.id}}_adjust_counter(self.read_attribute({{foreign_key}}), 1_i64)
          end
        end
      {% end %}
    end
  end
end
