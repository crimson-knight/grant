# crystal: strict
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
  # The checks behind the convenience format validators (`validates_email`,
  # `validates_url`). They are written by hand, so they work without Regex
  # support; `require "grant/regex"` adds the equivalent `EMAIL_REGEX` and
  # `URL_REGEX` constants for use with `validates_format_of`.
  module CommonFormats
    # Whether *value* is a conventional `local@domain.tld` email address: a
    # local part of word characters, `+`, `-` and `.`, then a domain of at
    # least two dot-separated labels of letters, digits and `-`, the last of
    # letters only (ASCII letters, compared ignoring case). Backs
    # `validates_email`.
    #
    # ```
    # Grant::Validators::BuiltIn::CommonFormats.email?("user@example.com") # => true
    # Grant::Validators::BuiltIn::CommonFormats.email?("not-an-email")     # => false
    # ```
    def self.email?(value : String) : Bool
      Grant::TextMatching.email?(value)
    end

    # Whether *value* is an `http`/`https` URL with a dotted host. Backs
    # `validates_url`.
    #
    # ```
    # Grant::Validators::BuiltIn::CommonFormats.url?("https://example.com") # => true
    # Grant::Validators::BuiltIn::CommonFormats.url?("ftp://example.com")   # => false
    # ```
    def self.url?(value : String) : Bool
      Grant::TextMatching.url?(value)
    end
  end
end
