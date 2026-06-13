# Mobile-target entrypoint for the compile-target column-gating specs.
#
# Selects the adapter and the build target with plain `require`s (NO `-D`
# flags) BEFORE the shared models expand, then runs the assertion harness.
require "../../../src/grant"
require "../../../src/adapter/sqlite"
require "../../../src/target/mobile" # sets GRANT_COMPILE_TARGET = :mobile
require "./gated_models"

GatedColumns.run
