# The three annotations Grant's strict files use, declared for compilers that
# do not define them.
#
# A Grant file whose first line is `# crystal: strict` is a strict Crystal
# file. agent-crystal reads that line and the annotations itself: it types a
# method that writes out all of its types once, instead of once per model.
# Public Crystal treats the first line as a comment and needs only the three
# names to exist, which this file provides. Every Grant file that uses one of
# the annotations requires this file, so it loads before the first use
# whichever Grant file an app requires first.
#
# Each declaration is skipped when the name already exists (agent-crystal's
# standard library, or the `strict` shard), so the compiler's own annotations
# stay the only ones.
#
# Adapted from the declare-only `strict` shard, `compat/strict/src/strict.cr`
# in https://github.com/crimson-knight/crystal at commit
# 8ccce497524ef3e35fdc48c487854ab0743b0541, licensed under Apache-2.0.

{% unless @top_level.has_constant?("Override") %}
  # Marks a `def` that replaces an earlier definition of the same method in
  # the same type, or overrides a method the type inherits.
  annotation Override
  end
{% end %}

{% unless @top_level.has_constant?("TypeOnce") %}
  # Types a method once, against the types its signature declares.
  annotation TypeOnce
  end
{% end %}

{% unless @top_level.has_constant?("TypeBound") %}
  # Declares the bound of a type parameter of a generic class
  # (`@[TypeBound(Model, Grant::Base)]`).
  annotation TypeBound
  end
{% end %}
