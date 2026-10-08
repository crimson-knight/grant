require "./builder"

class Grant::Query::Builder(Model)
  # `true` when records loaded through this relation are marked read-only.
  def readonly? : Bool
    @relation_state.readonly?
  end

  # Marks every record this relation loads read-only (`value = true`), so
  # `save`, `update` and `destroy` on it raise `Grant::ReadOnlyRecordError`.
  # `unscope(:readonly)` drops the flag. Returns `self`.
  #
  # ```
  # user = User.readonly.first!
  # user.update(email: "x@example.com") # raises Grant::ReadOnlyRecordError
  # ```
  def readonly!(value : Bool = true) : self
    reset_load_state
    @relation_state.readonly = value
    self
  end

  def readonly(value : Bool = true) : self
    chain_copy.readonly!(value)
  end
end
