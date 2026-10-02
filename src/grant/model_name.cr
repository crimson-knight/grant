# Naming for a model class, like ActiveModel::Name.
#
# ```
# name = Blog::Post.model_name
# name.singular           # => "blog_post"
# name.plural             # => "blog_posts"
# name.route_key          # => "blog_posts"
# name.singular_route_key # => "blog_post"
# name.collection         # => "blog/posts"
# name.human              # => "Post"
# name.human(count: 2)    # => the models.blog/post.other translation, else "Post"
# ```
struct Grant::ModelName
  # Nouns whose plural is their singular.
  UNCOUNTABLE = %w[equipment information rice money species series fish sheep news data metadata]

  IRREGULAR = {
    "person" => "people",
    "man"    => "men",
    "woman"  => "women",
    "child"  => "children",
    "mouse"  => "mice",
    "foot"   => "feet",
    "tooth"  => "teeth",
    "goose"  => "geese",
    "ox"     => "oxen",
    "quiz"   => "quizzes",
    "knife"  => "knives",
    "wife"   => "wives",
    "life"   => "lives",
    "leaf"   => "leaves",
    "half"   => "halves",
    "wolf"   => "wolves",
    "shelf"  => "shelves",
    "thief"  => "thieves",
    "hero"   => "heroes",
    "potato" => "potatoes",
    "tomato" => "tomatoes",
    "echo"   => "echoes",
    "veto"   => "vetoes",
  }

  # The class name, e.g. `"Blog::Post"`.
  getter name : String

  def initialize(@name : String)
  end

  # The translation key: `"blog/post"`.
  def i18n_key : String
    Grant::I18n.model_key(@name)
  end

  # The key used for form parameters: `"blog_post"`.
  def param_key : String
    i18n_key.tr("/", "_")
  end

  # `"blog_post"`.
  def singular : String
    param_key
  end

  # The pluralized `singular`: `"blog_posts"`.
  def plural : String
    self.class.pluralize(singular)
  end

  # The underscored class name without its namespace: `"post"`.
  def element : String
    Grant::I18n.demodulize(@name).underscore
  end

  # The path-style plural, namespaces kept: `"blog/posts"`.
  def collection : String
    namespace_path = i18n_key.rpartition('/')
    namespace_path[1].empty? ? self.class.pluralize(element) : "#{namespace_path[0]}/#{self.class.pluralize(element)}"
  end

  # The name of a route helper for a single record: `"blog_post"`.
  def singular_route_key : String
    singular
  end

  # The name of a route helper for the collection: `"blog_posts"`; an
  # uncountable noun gets an `_index` suffix (`"equipment_index"`) so it differs
  # from the singular route.
  def route_key : String
    key = plural
    key == singular ? "#{key}_index" : key
  end

  # The display name: the `models.<key>` translation or `"Blog post"`. With
  # *count*, the `models.<key>.one` / `.other` translation is preferred.
  def human(count : Int? = nil) : String
    Grant::I18n.human_model_name(@name, count)
  end

  def to_s(io : IO) : Nil
    io << @name
  end

  # English plural of the last word of *word* (an underscored name).
  def self.pluralize(word : String) : String
    return word if word.empty?
    prefix, separator, last = word.rpartition('_')
    tail = pluralize_word(last)
    separator.empty? ? tail : "#{prefix}_#{tail}"
  end

  private def self.pluralize_word(word : String) : String
    return word if UNCOUNTABLE.includes?(word)
    if plural = IRREGULAR[word]?
      return plural
    end
    IRREGULAR.each do |singular, irregular_plural|
      return word[0, word.size - singular.size] + irregular_plural if word.ends_with?(singular) && singular.size > 3
    end

    case word
    when /(?:s|x|z|ch|sh)\z/ then word + "es"
    when /[^aeiou]y\z/       then word[0, word.size - 1] + "ies"
    else                          word + "s"
    end
  end
end
