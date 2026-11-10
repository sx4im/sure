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

  test "PdfProcessingResult stringifies extracted_data keys, including nested ones" do
    result = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Statement",
      document_type: "bank_statement",
      extracted_data: {
        institution_name: "Bank of Example",
        nested: { account_holder: "Health Check" }
      }
    )

    assert_equal "Bank of Example", result.extracted_data["institution_name"]
    assert_equal "Health Check", result.extracted_data["nested"]["account_holder"]
    assert_nil result.extracted_data[:institution_name]
  end

  test "PdfProcessingResult tolerates a missing extracted_data" do
    result = Provider::LlmConcept::PdfProcessingResult.new(
      summary: "Statement",
      document_type: "bank_statement",
      extracted_data: nil
    )

    assert_equal({}, result.extracted_data)
  end
end
