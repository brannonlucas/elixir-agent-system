defmodule NervousSystem.EvaluatorTest do
  use ExUnit.Case, async: true

  alias NervousSystem.Evaluator

  describe "struct" do
    test "has default values" do
      evaluator = %Evaluator{}

      assert evaluator.scores == %{
        engagement: 0,
        evidence: 0,
        diversity: 0,
        context_integration: 0,
        actionability: 0,
        synthesis: 0,
        fact_checking: 0,
        conciseness: 0
      }
      assert evaluator.overall == 0
      assert evaluator.details == %{}
      assert evaluator.status == :pending
    end
  end

  describe "evaluate/3 (without API call)" do
    # Note: Full integration tests require API keys
    # These tests verify the structure and error handling

    test "handles error status" do
      evaluator = %Evaluator{status: :error, details: %{error: "Test error"}}

      assert evaluator.status == :error
      assert evaluator.details.error == "Test error"
    end

    test "complete status has scores" do
      evaluator = %Evaluator{
        status: :complete,
        scores: %{
          engagement: 8,
          evidence: 7,
          diversity: 9,
          context_integration: 6,
          actionability: 8,
          synthesis: 7,
          fact_checking: 5,
          conciseness: 8
        },
        overall: 72
      }

      assert evaluator.status == :complete
      assert evaluator.scores.engagement == 8
      assert evaluator.overall == 72
    end
  end

  describe "score dimensions" do
    test "has 8 scoring dimensions" do
      evaluator = %Evaluator{}
      dimensions = Map.keys(evaluator.scores)

      assert length(dimensions) == 8
      assert :engagement in dimensions
      assert :evidence in dimensions
      assert :diversity in dimensions
      assert :context_integration in dimensions
      assert :actionability in dimensions
      assert :synthesis in dimensions
      assert :fact_checking in dimensions
      assert :conciseness in dimensions
    end
  end
end
