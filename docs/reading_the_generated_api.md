# Reading the generated API

Grant defines most of a model's per-attribute and per-association methods with
**Crystal macros** (`column`, `belongs_to`, `has_many`, `enum_attribute`,
`has_secure_token`, …). Macros run at compile time and emit real methods, so the
methods exist and are fully typed — but `crystal docs` shows you the **macro**,
not each method the macro generates for your model.

This page is the decoder ring: given a `column` or association declaration in
your model, it tells you exactly which methods that one line produces, so you can
call them without guessing.

> Why it works this way: in a dynamic-runtime ORM (Ruby's ActiveRecord) the
> per-column methods are conjured at runtime via `method_missing`, so a doc tool
> can't see them either. Grant generates them **at compile time** instead — they
> are concrete, type-checked methods in your binary. The trade-off is that
> `crystal docs` renders the generating macro once, not the N methods it expands
> to for your specific columns.

## How to use this page

1. Find the declaration you wrote (`column …`, `belongs_to …`, etc.).
2. Read across to the **generated methods** column, substituting your own
   attribute/association name for the placeholder (`<name>`).
3. Those methods are real, typed, and callable on instances (or, for scopes, on
   the class).

Throughout, `<name>` is the declared attribute/association name and `<Type>` its
declared type.

---

## `column <name> : <Type>` — attribute methods

A single `column` declaration generates a getter, a setter, a nil-asserting
bang getter (for nilable columns), and the full **dirty-tracking** family.

| You wrote                          | Generated method                         | Returns / does                                            |
| ---------------------------------- | ---------------------------------------- | --------------------------------------------------------- |
| `column name : String`             | `#name`                                  | the value (`String`)                                      |
|                                    | `#name=(value)`                          | sets the value (in memory; `save` to persist)             |
| `column nickname : String?`        | `#nickname`                              | the value or `nil` (`String?`)                            |
|                                    | `#nickname!`                             | the value, raising `NilAssertionError` if `nil`           |
|                                    | `#nickname=(value)`                      | sets the value                                            |
| *(every column, incl. above)*      | `#<name>_changed?`                       | `Bool` — has it changed since load/last save?             |
|                                    | `#<name>_was`                            | the value **before** the current unsaved change           |
|                                    | `#<name>_change`                         | `Tuple(old, new)?` — the pending change, or `nil`         |
|                                    | `#<name>_before_last_save`               | the value as of **before the last `save`**                |

Worked example:

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  column email : String
  column nickname : String?
end

user = User.find!(1)
user.email                # => "ada@example.com"   (#email)
user.nickname             # => nil                  (#nickname — nilable getter)
user.email = "ada@new.io" # (#email=)
user.email_changed?       # => true                 (#email_changed?)
user.email_was            # => "ada@example.com"    (#email_was)
user.email_change         # => {"ada@example.com", "ada@new.io"}  (#email_change)
user.save
user.email_before_last_save # => "ada@example.com"  (#email_before_last_save)
```

The bang getter only exists for **nilable** columns (`String?`), where it
asserts non-nil:

```crystal
user.nickname!            # raises NilAssertionError when nickname is nil
```

The dirty-tracking methods above are the per-column conveniences. The generic,
name-by-string equivalents (`#attribute_changed?("email")`, `#attribute_was(...)`,
`#changed?`, `#changes`, `#previous_changes`, `#restore_attributes`) **do** render
on `Grant::Base` in `crystal docs` — consult them for the whole-record view.

### `timestamps`

`timestamps` is shorthand for two columns:

```crystal
timestamps
# expands to:
#   column created_at : Time?
#   column updated_at : Time?
```

so it generates the full attribute + dirty-tracking family for `created_at` and
`updated_at` (e.g. `#created_at`, `#updated_at=`, `#updated_at_changed?`). Grant
sets them automatically on create/update.

---

## `belongs_to` / `has_one` / `has_many` — association methods

| You wrote                            | Generated API                                                        |
| ------------------------------------ | -------------------------------------------------------------------- |
| `belongs_to :user`                   | `#user`, `#user!`, `#user=`, and a `user_id : Int64?` column         |
| `has_one :profile`                   | `#profile`, `#profile!`, `#profile=`                                 |
| `has_many :posts`                    | `#posts` (collection), `#post_ids`, `#post_ids=`                     |
| `has_many :posts, through: :memberships` | `#posts` (collection traversing the join)                        |
| `belongs_to :owner, polymorphic: true` | `#owner`, `#owner!`, `#owner=`, `#owner_proxy`, plus `owner_id`/`owner_type` columns |

Notes on the singular getters:

- `#user` returns `User?` — the owner, or a **blank** instance when the foreign
  key does not resolve. It caches an eager-loaded value if one was preloaded.
- `#user!` returns `User`, raising `Grant::Querying::NotFound` when absent — use
  it when the association must exist.
- `#user=(parent)` sets `user_id = parent.id` **in memory**; call `save` to
  persist.

Worked example:

```crystal
class Author < Grant::Base
  column id : Int64, primary: true
  column name : String
  has_many :books
end

class Book < Grant::Base
  column id : Int64, primary: true
  column title : String
  belongs_to :author            # => #author, #author!, #author=, author_id
end

book = Book.find!(1)
book.author          # => Author?   (#author — blank Author if FK unresolved)
book.author!         # => Author    (#author!, raises if absent)
book.author_id       # => 1         (the generated FK column)

author = Author.find!(1)
author.books         # => collection (#books) — chainable, Enumerable
author.book_ids      # => [1, 2, 3] (#book_ids)
author.books.where(title: "Dune").to_a   # collections are query-chainable
```

For the full association guide (options like `dependent:`, `counter_cache:`,
`through:`, polymorphic, eager loading), see
[`relationships.md`](relationships.md),
[`advanced_associations.md`](advanced_associations.md), and
[`polymorphic_associations.md`](polymorphic_associations.md).

---

## `enum_attribute <name> : <EnumType>` — enum helpers

For `enum_attribute status : Status` where `Status` has members `Draft`,
`Published`, `Archived`:

| Generated                        | Kind            | Does                                              |
| -------------------------------- | --------------- | ------------------------------------------------- |
| `#draft?`, `#published?`, `#archived?` | instance predicate | `Bool` — is `status` that member?           |
| `#draft!`, `#published!`, `#archived!` | instance bang-setter | assign that member to `status`, return it   |
| `.draft`, `.published`, `.archived`    | class scope     | a query filtered to that member                   |
| `.statuses`                      | class method    | `Array(Status)` of all members                    |
| `.status_mapping`                | class method    | `Hash` of underscored member name ⇒ enum value    |

Plus the underlying `status` column itself (with all the column methods above).

```crystal
post = Post.new
post.draft?       # => true        (#draft?)
post.published!   # => Post::Status::Published   (#published!)
post.published?   # => true        (#published?)
Post.published    # query scoped to status == Published   (.published)
Post.statuses     # => [Draft, Published, Archived]        (.statuses)
```

---

## `has_secure_token <name>` — token helpers

`has_secure_token :auth_token` generates:

| Generated                  | Does                                                            |
| -------------------------- | -------------------------------------------------------------- |
| an `auth_token : String?` column | auto-populated with a random token on create (if unset)  |
| `#regenerate_auth_token`   | rotates `auth_token` to a fresh value and persists it          |

```crystal
class User < Grant::Base
  column id : Int64, primary: true
  has_secure_token :auth_token            # 24-char base58 by default
  has_secure_token :api_key, length: 32, alphabet: :hex
end

u = User.create
u.auth_token              # => "rX9kLm2pQvNbT7wYzA4cDeF8" (set on create)
u.regenerate_auth_token   # rotate it
```

See [`secure_tokens.md`](secure_tokens.md) for `has_secure_token`, `signed_id`,
and `token_for`, and [`ENCRYPTED_ATTRIBUTES.md`](ENCRYPTED_ATTRIBUTES.md) for
encrypted attributes.

---

## The general rule

| Declaration kind        | `crystal docs` shows | Your model actually gains                                  |
| ----------------------- | -------------------- | ---------------------------------------------------------- |
| `column`                | the `column` macro   | `#<name>`, `#<name>=`, `#<name>!` (nilable), `#<name>_changed?`, `#<name>_was`, `#<name>_change`, `#<name>_before_last_save` |
| `belongs_to`            | the `belongs_to` macro | `#<name>`, `#<name>!`, `#<name>=`, `<name>_id` column     |
| `has_one`               | the `has_one` macro  | `#<name>`, `#<name>!`, `#<name>=`                          |
| `has_many`              | the `has_many` macro | `#<name>` (collection), `#<singular>_ids`, `#<singular>_ids=` |
| `enum_attribute`        | the `enum_attribute` macro | `#<member>?`, `#<member>!`, `.<member>` (scope), `.<plural>`, `.<name>_mapping` |
| `has_secure_token`      | the `has_secure_token` macro | `<name>` column, `#regenerate_<name>`              |
| `timestamps`            | the `timestamps` macro | `created_at`/`updated_at` columns (full column family each) |

When in doubt: the macro's own doc comment in `crystal docs` lists what it
generates (the association and enum macros include a generated-API table). Read
the macro, substitute your name, and the methods are there.
