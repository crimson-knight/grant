module Grant::Validators
  # :nodoc:
  # The match `validates_format_of` runs. Defined only by `require "grant/regex"`,
  # which is how the macro knows Regex support was asked for.
  module FormatMatching
    def self.matches?(value : String, pattern : Regex) : Bool
      value.matches?(pattern)
    end
  end

  module BuiltIn::CommonFormats
    # Case-insensitive pattern matching a conventional `local@domain.tld`
    # email address; `email?` accepts exactly the same values. Use it with
    # `validates_format_of` for the same check under other options.
    #
    # ```
    # validates_format_of :email,
    #   with: Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX,
    #   message: "must be a valid email"
    # ```
    EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

    # Pattern matching an `http`/`https` URL; `url?` accepts exactly the same
    # values.
    URL_REGEX = /\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
  end
end
