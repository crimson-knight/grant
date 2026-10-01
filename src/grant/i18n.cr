require "./error"

# Localized error messages and attribute names.
#
# Every message Grant generates from an error type (`errors.add(:name,
# :too_short, count: 3)`, `message: :custom_key`, or a validator's default
# message) is looked up through the current `Grant::I18n.translator`. The
# default translator holds the English table below and can be extended or
# overridden per application, per model or per attribute:
#
# ```
# Grant::I18n.store("errors.messages.blank", "is required")
# Grant::I18n.store("errors.models.user.attributes.email.blank", "needs an address")
# Grant::I18n.store("attributes.user.email", "E-mail address")
# ```
#
# An application that uses a translation library plugs it in with its own
# `Grant::I18n::Translator` subclass:
#
# ```
# class MyTranslator < Grant::I18n::Translator
#   def translate(locale : String, key : String) : String?
#     MyI18n.lookup(locale, key)
#   end
# end
#
# Grant::I18n.translator = MyTranslator.new
# ```
#
# A translator returns the message *template* (`"is too short (minimum is
# %{count} characters)"`); Grant interpolates `%{count}`, `%{attribute}`,
# `%{model}`, `%{value}` and any other option itself.
#
# Lookups are cached per (locale, model class, attribute, type), so a message
# costs a hash lookup after the first time. Changing the translator, the
# default locale or the store clears the cache.
#
# `Grant::I18n.locale=` sets the process default. `Grant::I18n.with_locale`
# overrides it for the current fiber only (a web request serving a French
# visitor does not change the locale another request sees):
#
# ```
# Grant::I18n.with_locale("fr") { record.valid?; record.errors.full_messages }
# ```
module Grant::I18n
  # Looks up message templates by key. `nil` means "no translation here", and
  # the next key in Grant's lookup order is tried.
  abstract class Translator
    abstract def translate(locale : String, key : String) : String?
  end

  # The built-in English table plus whatever the application stores.
  class DefaultTranslator < Translator
    # The messages Grant ships with. Keys follow the ActiveRecord layout
    # without the `activerecord.` prefix.
    MESSAGES = {
      "errors.format"                            => "%{attribute} %{message}",
      "errors.messages.blank"                    => "can't be blank",
      "errors.messages.present"                  => "must be blank",
      "errors.messages.taken"                    => "has already been taken",
      "errors.messages.invalid"                  => "is invalid",
      "errors.messages.inclusion"                => "is not included in the list",
      "errors.messages.exclusion"                => "is reserved",
      "errors.messages.confirmation"             => "doesn't match confirmation",
      "errors.messages.accepted"                 => "must be accepted",
      "errors.messages.empty"                    => "can't be empty",
      "errors.messages.too_short"                => "is too short (minimum is %{count} characters)",
      "errors.messages.too_long"                 => "is too long (maximum is %{count} characters)",
      "errors.messages.wrong_length"             => "is the wrong length (should be %{count} characters)",
      "errors.messages.not_a_number"             => "is not a number",
      "errors.messages.not_an_integer"           => "must be an integer",
      "errors.messages.greater_than"             => "must be greater than %{count}",
      "errors.messages.greater_than_or_equal_to" => "must be greater than or equal to %{count}",
      "errors.messages.equal_to"                 => "must be equal to %{count}",
      "errors.messages.less_than"                => "must be less than %{count}",
      "errors.messages.less_than_or_equal_to"    => "must be less than or equal to %{count}",
      "errors.messages.other_than"               => "must be other than %{count}",
      "errors.messages.odd"                      => "must be odd",
      "errors.messages.even"                     => "must be even",
      "errors.messages.comparison"               => "failed comparison",
      "errors.messages.required"                 => "must exist",
      "errors.messages.invalid_email"            => "is not a valid email",
      "errors.messages.invalid_url"              => "is not a valid URL",
      "errors.messages.out_of_range"             => "is out of range",
    }

    def initialize
      @store = {} of String => String
      # The translator is shared by every fiber; stores can happen while
      # other fibers look messages up.
      @store_mutex = Mutex.new
    end

    # Registers *template* under *key* for *locale*.
    def store(key : String, template : String, locale : String = "en") : Nil
      stored_key = "#{locale}.#{key}"
      @store_mutex.synchronize { @store[stored_key] = template }
    end

    def translate(locale : String, key : String) : String?
      stored_key = "#{locale}.#{key}"
      stored = @store_mutex.synchronize { @store[stored_key]? }
      stored || (locale == "en" ? MESSAGES[key]? : nil)
    end
  end

  @@translator : Translator = DefaultTranslator.new
  @@locale = "en"
  @@mutex = Mutex.new
  # The number of `with_locale` blocks running now, in any fiber. While it is
  # zero `locale` reads the process default without touching the fiber.
  @@scoped_locales = Atomic(Int32).new(0)
  @@message_cache = {} of {String, String, String, Symbol} => String
  @@name_cache = {} of {String, String, String} => String
  @@format_cache = {} of String => String

  # The active translator.
  def self.translator : Translator
    @@translator
  end

  # Replaces the translator and clears the caches.
  def self.translator=(translator : Translator)
    @@translator = translator
    clear_cache
    translator
  end

  # The locale passed to the translator: the current fiber's `with_locale`
  # override when one is running, otherwise the process default (`"en"`).
  def self.locale : String
    return @@locale if @@scoped_locales.get == 0
    Fiber.current.grant_locale || @@locale
  end

  # Sets the process default locale.
  def self.locale=(locale : String)
    @@locale = locale
    clear_cache
    locale
  end

  # Runs the block with *locale* as the locale of the current fiber, then
  # restores what it was. Other fibers keep their own locale.
  def self.with_locale(locale : String, &)
    fiber = Fiber.current
    previous = fiber.grant_locale
    fiber.grant_locale = locale
    @@scoped_locales.add(1)
    begin
      yield
    ensure
      @@scoped_locales.sub(1)
      fiber.grant_locale = previous
    end
  end

  # Stores a template on the default translator. Raises when a custom
  # translator is installed, because only it knows where its data lives.
  def self.store(key : String, template : String, locale : String = "en") : Nil
    translator = @@translator
    unless translator.is_a?(DefaultTranslator)
      raise ArgumentError.new("Grant::I18n.store only works with the default translator; add the key to your own translator")
    end
    translator.store(key, template, locale)
    clear_cache
  end

  # Forgets every cached lookup. Call it after changing a custom translator's
  # data at run time.
  def self.clear_cache : Nil
    @@mutex.synchronize do
      @@message_cache.clear
      @@name_cache.clear
      @@format_cache.clear
    end
  end

  # `"first_name"` becomes `"First name"`, `"author_id"` becomes `"Author"`.
  def self.humanize(name : String) : String
    text = name.size > 3 && name.ends_with?("_id") ? name[0, name.size - 3] : name
    text.tr("_.", "  ").capitalize
  end

  # The display name of *attribute* on the model named *model*: the
  # `attributes.<model>.<attribute>` (or `attributes.<attribute>`) translation
  # when there is one, otherwise the humanized attribute name.
  def self.human_attribute_name(model : String, attribute : String) : String
    locale = self.locale
    key = {locale, model, attribute}
    @@mutex.synchronize do
      @@name_cache[key] ||= begin
        model_key = model_key(model)
        translator = @@translator
        translator.translate(locale, "attributes.#{model_key}.#{attribute}") ||
          translator.translate(locale, "attributes.#{attribute}") ||
          humanize(attribute)
      end
    end
  end

  # The display name of the model itself (`"Blog post"` for `Blog::Post`).
  def self.human_model_name(model : String) : String
    translator = @@translator
    translator.translate(locale, "models.#{model_key(model)}") || humanize(demodulize(model).underscore)
  end

  # `"Blog::Post"` becomes `"blog/post"`, the key used in translation files.
  def self.model_key(model : String) : String
    model.underscore.gsub("::", "/")
  end

  # `"Blog::Post"` becomes `"Post"`.
  def self.demodulize(model : String) : String
    model.split("::").last
  end

  # Builds the message for an error of *type* on *attribute*. Looks up, in
  # order, `errors.models.<model>.attributes.<attribute>.<type>`,
  # `errors.models.<model>.<type>`, `errors.attributes.<attribute>.<type>` and
  # `errors.messages.<type>`, then interpolates the options.
  def self.generate_message(base : Grant::Base?, attribute : String, type : Symbol, options : Grant::Error::Options? = nil) : String
    model = base ? base.class.name : ""
    template = template_for(model, attribute, type)
    interpolate(template, base, attribute, options)
  end

  # "Attribute message" formatted through the `errors.format` template.
  def self.full_message(human_attribute : String, message : String) : String
    template = format_template
    if template == "%{attribute} %{message}"
      String.build(human_attribute.bytesize + message.bytesize + 1) do |io|
        io << human_attribute << ' ' << message
      end
    else
      template.gsub(/%\{(attribute|message)\}/) { |_, match| match[1] == "attribute" ? human_attribute : message }
    end
  end

  # Replaces `%{name}` placeholders in *template*.
  def self.interpolate(template : String, base : Grant::Base?, attribute : String, options : Grant::Error::Options?) : String
    return template unless template.includes?("%{")
    template.gsub(/%\{(\w+)\}/) do |whole, match|
      name = match[1]
      found = nil
      options.try &.each do |key, value|
        if key.to_s == name
          found = value.to_s
          break
        end
      end
      if found
        found
      elsif name == "attribute"
        base ? base.class.human_attribute_name(attribute) : humanize(attribute)
      elsif name == "model"
        base ? base.class.model_name.human : ""
      else
        whole
      end
    end
  end

  private def self.format_template : String
    locale = self.locale
    @@mutex.synchronize do
      @@format_cache[locale] ||= @@translator.translate(locale, "errors.format") || "%{attribute} %{message}"
    end
  end

  private def self.template_for(model : String, attribute : String, type : Symbol) : String
    locale = self.locale
    key = {locale, model, attribute, type}
    @@mutex.synchronize do
      @@message_cache[key] ||= lookup(locale, model, attribute, type)
    end
  end

  private def self.lookup(locale : String, model : String, attribute : String, type : Symbol) : String
    translator = @@translator
    unless model.empty?
      model_key = model_key(model)
      found = translator.translate(locale, "errors.models.#{model_key}.attributes.#{attribute}.#{type}") ||
              translator.translate(locale, "errors.models.#{model_key}.#{type}")
      return found if found
    end
    translator.translate(locale, "errors.attributes.#{attribute}.#{type}") ||
      translator.translate(locale, "errors.messages.#{type}") ||
      translator.translate(locale, "errors.messages.invalid") ||
      "is invalid"
  end
end

class Fiber
  # The locale `Grant::I18n.with_locale` set for this fiber, if any.
  # :nodoc:
  property grant_locale : String?
end

# Naming for a model class, like ActiveModel::Name.
struct Grant::ModelName
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

  # The underscored class name without its namespace: `"post"`.
  def element : String
    Grant::I18n.demodulize(@name).underscore
  end

  # The display name: the `models.<key>` translation or `"Blog post"`.
  def human : String
    Grant::I18n.human_model_name(@name)
  end

  def to_s(io : IO) : Nil
    io << @name
  end
end

abstract class Grant::Base
  # The `Grant::ModelName` of this model.
  #
  # ```
  # BlogPost.model_name.human # => "Blog post"
  # ```
  def self.model_name : Grant::ModelName
    Grant::ModelName.new(self.name)
  end

  # The display name of *attribute*: the `attributes.<model>.<attribute>`
  # translation or the humanized attribute (`"First name"`).
  #
  # ```
  # User.human_attribute_name(:first_name) # => "First name"
  # ```
  def self.human_attribute_name(attribute : Symbol | String) : String
    Grant::I18n.human_attribute_name(self.name, attribute.to_s)
  end
end
