module Grant::Mica
  struct Decimal128
    # How `divide`, `round` and `rescale` choose a result that sits between
    # two values at the result scale.
    #
    # | Mode | 2.5 | -2.5 | 2.4 | -2.6 |
    # |---|---|---|---|---|
    # | `TiesAway` | 3 | -3 | 2 | -3 |
    # | `TiesEven` | 2 | -2 | 2 | -3 |
    # | `Floor` | 2 | -3 | 2 | -3 |
    # | `Ceiling` | 3 | -2 | 3 | -2 |
    # | `Truncate` | 2 | -2 | 2 | -2 |
    # | `Unnecessary` | raises | raises | raises | raises |
    enum RoundingMode
      # The nearest value; a tie goes away from zero (half up).
      TiesAway
      # The nearest value; a tie goes to the even last digit (banker's rounding).
      TiesEven
      # Toward negative infinity.
      Floor
      # Toward positive infinity.
      Ceiling
      # Toward zero.
      Truncate
      # Exact only: raises `InexactError` when a nonzero digit would be dropped.
      Unnecessary
    end
  end
end
