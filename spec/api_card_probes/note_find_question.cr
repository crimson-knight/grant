require "./probe_support"

class GrantAPICardFindQuestionProbe < Grant::Base
  table :api_card_find_question_probes
  column id : Int64, primary: true

  macro assert_find_question_missing
    {% if @type.class.has_method?(:find?) %}
      {% raise "Grant does not define find?" %}
    {% end %}
  end

  assert_find_question_missing
end
