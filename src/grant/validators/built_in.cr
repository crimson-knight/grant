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
  # Common format validators — regex constants
  module CommonFormats
    EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
    URL_REGEX   = /\Ahttps?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/\/=]*)\z/
  end
end
