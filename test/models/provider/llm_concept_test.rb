require "test_helper"

class Provider::LlmConceptTest < ActiveSupport::TestCase
  test "max_items_per_call prefers ENV, then the setting, then 25" do
    Setting.stubs(:llm_max_items_per_call).returns(40)
    with_env_overrides("LLM_MAX_ITEMS_PER_CALL" => "7") do
      assert_equal 7, Provider::LlmConcept.max_items_per_call
    end
    with_env_overrides("LLM_MAX_ITEMS_PER_CALL" => nil) do
      assert_equal 40, Provider::LlmConcept.max_items_per_call
      Setting.stubs(:llm_max_items_per_call).returns(nil)
      assert_equal 25, Provider::LlmConcept.max_items_per_call
    end
  end

  test "PdfProcessingResult stringifies extracted_data keys regardless of provider" do
    result = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Statement",
      document_type: "bank_statement",
      extracted_data: {
        institution_name: "SUREHEALTHCHECKBANK",
        nested: { account_holder: "Health Check" }
      }
    )

    assert_equal "SUREHEALTHCHECKBANK", result.extracted_data["institution_name"]
    assert_equal "Health Check", result.extracted_data["nested"]["account_holder"]
    assert_not result.extracted_data.key?(:institution_name)
  end

  test "PdfProcessingResult passes non-hash extracted_data through unchanged" do
    result = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Statement",
      document_type: "other",
      extracted_data: nil
    )

    assert_nil result.extracted_data
  end
end
