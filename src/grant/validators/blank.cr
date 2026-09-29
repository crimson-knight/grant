# ActiveRecord-compatible blankness, shared by `validates_presence_of`,
# `validates_absence_of` and every `allow_blank:` option.
#
# A value is blank when it is `nil`, `false`, a String of only whitespace, or
# an empty Array/Hash/Set (any collection that answers `empty?`). Numbers,
# `true`, Symbols and Time values are never blank.
module Grant::Validators
  def self.blank?(value : Nil) : Bool
    true
  end

  def self.blank?(value : String) : Bool
    value.blank?
  end

  def self.blank?(value : Bool) : Bool
    !value
  end

  def self.blank?(value : Number) : Bool
    false
  end

  def self.blank?(value : Array | Hash | Set | Slice) : Bool
    value.empty?
  end

  def self.blank?(value) : Bool
    if value.responds_to?(:blank?)
      value.blank?
    elsif value.responds_to?(:empty?)
      value.empty?
    else
      false
    end
  end
end
