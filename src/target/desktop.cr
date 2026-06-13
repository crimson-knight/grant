# Selects the **desktop** compile target for Grant's per-target column gating.
#
# `require` this file **before** your models are required so the constant is
# defined when the `column` macro expands:
#
# ```
# require "grant"
# require "grant/adapter/sqlite" # adapter selection is just a require
# require "grant/target/desktop" # ← sets GRANT_COMPILE_TARGET = :desktop
# require "./models"             # models expand AFTER the target is set
# ```
#
# With this target active, a `column ..., targets: [...]` is emitted only when
# `:desktop` is in its `targets` list (and ungated columns are always emitted).
# See `docs/compile_target_adapters.md`.
#
# There is no `-D` flag and no macro: the target is a plain top-level constant
# the `column` macro reads via `@top_level`. To define your own custom target,
# set `GRANT_COMPILE_TARGET` yourself before requiring your models instead of
# requiring one of these files (e.g. `GRANT_COMPILE_TARGET = :kiosk`).
GRANT_COMPILE_TARGET = :desktop
