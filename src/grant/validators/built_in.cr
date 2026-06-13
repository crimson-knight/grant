# Built-in validators for Grant ORM
#
# Provides Rails-style validation helpers for common validation patterns.
# All validators support `:if`, `:unless`, and `:on` conditional options.
#
# The `:on` option restricts when the validator runs:
# - `on: :create` — only when saving a new record
# - `on: :update` — only when updating an existing record
# - `on: :save` — on both create and update (default)
#
# The validator macros are defined inside `Grant::Validators`'s `macro inherited`
# block so they are available in every `Grant::Base` subclass even when compiled
# standalone. This file provides shared constants.

module Grant::Validators::BuiltIn
  # Shared regular-expression constants used by the convenience format
  # validators (`validates_email`, `validates_url`).
  #
  # Reference these directly with `validates_format_of` when you want the same
  # pattern under a custom message or option set:
  #
  # ```
  # class User < Grant::Base
  #   column id : Int64, primary: true
  #   column email : String?
  #
  #   validates_format_of :email,
  #     with: Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX,
  #     message: "must be a valid email"
  # end
  # ```
  module CommonFormats
    # Case-insensitive pattern matching a conventional `local@domain.tld`
    # email address. Backs `validates_email`.
    #
    # ```
    # "user@example.com".matches?(Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX) # => true
    # "not-an-email".matches?(Grant::Validators::BuiltIn::CommonFormats::EMAIL_REGEX)     # => false
    # ```
    EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i

    # Pattern matching an `http`/`https` URL. Backs `validates_url`.
    #
    # ```
    # "https://example.com".matches?(Grant::Validators::BuiltIn::CommonFormats::URL_REGEX) # => true
    # "ftp://example.com".matches?(Grant::Validators::BuiltIn::CommonFormats::URL_REGEX)   # => false
    # ```
    URL_REGEX = /\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
  end
end
