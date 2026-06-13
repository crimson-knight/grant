require "../spec_helper"

# Regression coverage for two release-blocking serialization bugs:
#
#   * Issue #41: defining a second `Grant::Base` subclass broke YAML/JSON
#     deserialization program-wide, because the abstract `Grant::Base` itself was
#     not `YAML::Serializable` / `JSON::Serializable` (the includes only fired
#     inside `macro inherited`). Any context expecting `YAML::Serializable?`
#     (e.g. Amber's `Amber::Configuration::CustomRegistry#load_custom_from_yaml`)
#     failed to compile the moment Crystal widened a union of two-or-more
#     subclasses to `Grant::Base+`.
#
#   * Issue #39: a model with a UUID column failed YAML deserialization because
#     `uuid/yaml` (which defines `UUID.new(YAML::ParseContext, YAML::Nodes::Node)`)
#     was never required.
#
# The decisive proof for issue #41 is that the helpers below COMPILE: their
# parameter/return types are `YAML::Serializable?` / `JSON::Serializable?` and
# they are handed `Grant::Base+` instances. Before the fix, the abstract
# `Grant::Base` was not (de)serializable, so assigning a model where a
# `YAML::Serializable?` was expected did not compile.

# Accepts any Grant model where a `YAML::Serializable?` / `JSON::Serializable?`
# is expected. This only compiles if abstract `Grant::Base` (and therefore the
# widened `Grant::Base+`) satisfies the serializable module — the core of #41.
def expects_yaml_serializable(value : YAML::Serializable?) : YAML::Serializable?
  value
end

def expects_json_serializable(value : JSON::Serializable?) : JSON::Serializable?
  value
end

describe "multi-model serialization (issues #41 / #39)" do
  it "treats abstract Grant::Base as YAML::Serializable (union of subclasses)" do
    # Two distinct concrete subclasses widen to Grant::Base+; passing either
    # where a YAML::Serializable? is expected only compiles if the abstract
    # base satisfies YAML::Serializable.
    models = [Todo.new(name: "a", priority: 1), Review.new] of Grant::Base
    models.each do |model|
      expects_yaml_serializable(model).should_not be_nil
    end
  end

  it "treats abstract Grant::Base as JSON::Serializable (union of subclasses)" do
    models = [Todo.new(name: "a", priority: 1), Review.new] of Grant::Base
    models.each do |model|
      expects_json_serializable(model).should_not be_nil
    end
  end

  it "round-trips two distinct models through YAML without breaking each other" do
    todo = Todo.from_yaml("---\nname: yaml todo\npriority: 7\n")
    todo.name.should eq "yaml todo"
    todo.priority.should eq 7

    review = Review.from_yaml("---\nname: yaml review\nupvotes: 3\nsentiment: 1.5\ninterest: 2.5\npublished: true\n")
    review.name.should eq "yaml review"
    review.upvotes.should eq 3
  end

  it "deserializes a model with a UUID column from YAML (issue #39)" do
    uuid = "12345678-1234-1234-1234-123456789012"
    model = UUIDNaturalModel.from_yaml("---\nuuid: #{uuid}\n")
    model.uuid.should eq UUID.new(uuid)
  end

  it "deserializes a model with a UUID column from JSON" do
    uuid = "12345678-1234-1234-1234-123456789012"
    model = UUIDNaturalModel.from_json(%({"uuid":"#{uuid}"}))
    model.uuid.should eq UUID.new(uuid)
  end

  it "accepts a UUID-bearing model where a YAML::Serializable? is expected" do
    # Exercises both fixes at once: a UUID-column model that is also a
    # Grant::Base+ used in a YAML::Serializable? context.
    model = UUIDNaturalModel.new
    expects_yaml_serializable(model).should_not be_nil
  end
end
