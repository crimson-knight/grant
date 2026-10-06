class Grant::Collection(M)
  forward_missing_to collection

  def initialize(@loader : -> Array(M)) : Nil
    @loaded = false
    @collection = [] of M
  end

  def loaded? : Bool
    @loaded
  end

  private getter loader

  private def collection
    return @collection if loaded?

    @collection = loader.call
    @loaded = true
    @collection
  end
end
