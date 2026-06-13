# Web-target entrypoint for the compile-target column-gating specs.
#
# Selects the adapter and the build target with plain `require`s (NO `-D`
# flags) BEFORE the shared models expand, then runs the assertion harness.
# The web target uses Postgres; the program never opens a real connection (it
# only introspects `fields` and (de)serializes in memory).
require "../../../src/grant"
require "../../../src/adapter/pg"
require "../../../src/target/web" # sets GRANT_COMPILE_TARGET = :web
require "./gated_models"

GatedColumns.run
