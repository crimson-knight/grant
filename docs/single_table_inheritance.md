# Single Table Inheritance (STI)

Single Table Inheritance lets an entire class hierarchy share one database
table. A discriminator column (by default `type`) records which concrete class
each row belongs to, so loading a row instantiates the correct subclass.

STI is ideal for modelling type-safe variants that share most of their data but
differ in behaviour — for example a `Persona` base with `AdminPersona` and
`MemberPersona` subclasses, each carrying type-specific permission behaviour.

## Enabling STI

Enable STI on the **root** of the hierarchy by including `Grant::STI` and
declaring the inheritance column. Subclasses simply inherit — they do **not**
include the module again.

```crystal
require "grant/sti" # already required by `require "grant"`

class Persona < Grant::Base
  include Grant::STI

  column id : Int64, primary: true
  column type : String   # the STI discriminator column
  column name : String
  column role : String?

  def permissions : Array(String)
    ["read"]
  end
end

class AdminPersona < Persona
  column access_level : Int32?

  def permissions : Array(String)
    ["read", "write", "admin"]
  end
end

class MemberPersona < Persona
  column membership_tier : String?

  def permissions : Array(String)
    ["read", "comment"]
  end
end
```

### The shared table

Every class in the hierarchy uses the root's table. Create it once with the
**union of all columns** across the hierarchy (a single migration), because the
table must hold every subclass's columns:

```sql
CREATE TABLE personas (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  type            VARCHAR(255) NOT NULL,
  name            VARCHAR(255) NOT NULL,
  role            VARCHAR(255),
  access_level    INTEGER,        -- AdminPersona
  membership_tier VARCHAR(255)    -- MemberPersona
);
```

Index the `type` column for query performance.

## Creating records

The inheritance column is set automatically on create:

```crystal
admin  = AdminPersona.create!(name: "Alice", access_level: 9)  # type => "AdminPersona"
member = MemberPersona.create!(name: "Bob", membership_tier: "gold")  # type => "MemberPersona"
```

## Querying

### Subclass queries filter by type (including descendants)

A subclass query is automatically scoped to its own type **and any registered
descendant types** (ActiveRecord semantics):

```crystal
AdminPersona.all          # WHERE type IN ('AdminPersona', <descendants...>)
MemberPersona.where(...)  # WHERE type = 'MemberPersona' AND ...
```

The STI type filter composes with your own `where`, `order`, etc.

### Root queries return the whole hierarchy

A root query applies **no** type filter and returns every row, each
instantiated as its correct concrete subclass:

```crystal
Persona.all.each do |p|
  p.class        # => AdminPersona / MemberPersona / Persona
  p.permissions  # dispatches to the concrete subclass
end

Persona.find(admin.id).class  # => AdminPersona
```

### `unscoped` bypasses the STI filter

```crystal
AdminPersona.unscoped.select  # no type filter
```

## Type casting: `becomes` and `becomes!`

`becomes` converts a record to another class in the same hierarchy **in
memory**, copying all attributes faithfully (including `nil`/`false`),
preserving dirty state, the `new_record`/`persisted` flags, and the primary
key. The database is not touched:

```crystal
member = admin.becomes(MemberPersona)  # in memory only
```

`becomes!` additionally persists the new type to the database via a
parameterized `UPDATE`:

```crystal
admin.becomes!(MemberPersona)
Persona.find!(admin.id).class  # => MemberPersona
```

## Immutable type column

The inheritance column cannot be written directly on a persisted record — use
`becomes!` to change a record's type. The guard uses an explicit mutability
flag (no backtrace/`caller` inspection):

```crystal
admin = AdminPersona.create!(name: "Alice")
admin.write_attribute("type", "MemberPersona")  # raises Grant::STI::ImmutableTypeError
```

New (unsaved) records may set the type column freely (the auto-set callback
relies on this).

## Custom inheritance column

Override `inheritance_column` on the root to use a different column name:

```crystal
class Document < Grant::Base
  include Grant::STI

  def self.inheritance_column : String
    "doc_type"
  end

  column id : Int64, primary: true
  column doc_type : String
  column title : String
end

class Contract < Document
  column counterparty : String?
end
```

## Serialization

`JSON::Serializable` / `YAML::Serializable` work across the whole hierarchy,
including multi-level subclasses (`SuperAdmin < Admin < Persona`). A subclass
round-trips back to its own type:

```crystal
restored = MemberPersona.from_json(member.to_json)  # => MemberPersona
```

## Exceptions

- `Grant::STI::SubclassNotFound` — a stored `type` value does not map to a
  registered class (ensure the subclass is defined/required).
- `Grant::STI::ImmutableTypeError` — direct write to the inheritance column on a
  persisted record.
- `Grant::STI::TypeCastingError` — an STI type conversion failed.

## Limitations

These are deliberate, documented boundaries of the current implementation:

1. **Base-class queries populate shared columns only.** `Persona.all` selects
   the root's columns, so returned instances are correctly typed (e.g.
   `AdminPersona`) and their **shared** columns are populated, but
   **subclass-only** columns (e.g. `access_level`, `membership_tier`) are
   `nil`. Query the subclass directly (`AdminPersona.all`,
   `MemberPersona.find_by(...)`) to hydrate every column. The same applies one
   level down: `AdminPersona.all` returns `SuperAdminPersona` rows correctly
   typed but with `SuperAdminPersona`-only columns left `nil`.

2. **Validators registered on a base class do not auto-run on subclass
   instances.** Crystal class variables are per-class, so the validator store
   declared on `Persona` is not shared with `AdminPersona`. Declare shared
   validations on each concrete class, or implement shared logic in a
   `before_validation` callback. (Subclass-specific `validate` blocks must use
   the base type for their block parameter.)

3. **`unscoped` on a subclass** returns rows of unrelated sibling types typed as
   the queried subclass with only the shared columns populated (it cannot
   re-type them, since the result collection is `Array(Subclass)`).
