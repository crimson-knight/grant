# The `before_add`, `after_add`, `before_remove` and `after_remove` hooks of one
# `has_many` association. A `before_` hook that returns `false` vetoes the
# operation; the `has_many` macro builds these from the association options.
struct Grant::AssociationCallbacks(Target)
  getter before_add : Proc(Target, Bool)?
  getter after_add : Proc(Target, Bool)?
  getter before_remove : Proc(Target, Bool)?
  getter after_remove : Proc(Target, Bool)?

  def initialize(@before_add : Proc(Target, Bool)? = nil, @after_add : Proc(Target, Bool)? = nil,
                 @before_remove : Proc(Target, Bool)? = nil, @after_remove : Proc(Target, Bool)? = nil)
  end
end
