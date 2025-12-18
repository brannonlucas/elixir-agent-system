defmodule NervousSystem.Evaluator do
  @moduledoc """
  Evaluates discussion quality using LLM analysis.

  Scores deliberations across 8 dimensions:
  - Engagement: Did agents respond to each other?
  - Evidence: Were claims backed by data/sources?
  - Diversity: Did agents genuinely disagree?
  - Context Integration: Did agents address user's situation?
  - Actionability: Were concrete next steps provided?
  - Synthesis: Did the synthesis capture the discussion?
  - Fact Checking: Were claims verified?
  - Conciseness: Did agents stay focused?
  """

  require Logger

  alias NervousSystem.Providers.Anthropic

  defstruct [
    scores: %{
      engagement: 0,
      evidence: 0,
      diversity: 0,
      context_integration: 0,
      actionability: 0,
      synthesis: 0,
      fact_checking: 0,
      conciseness: 0
    },
    overall: 0,
    details: %{},
    status: :pending
  ]

  @evaluation_prompt """
  You are evaluating a multi-agent deliberation. Score each dimension from 0-10.

  ## Topic
  {topic}

  ## User Context
  {user_context}

  ## Transcript
  {transcript}

  ## Scoring Criteria

  1. **Engagement** (0-10): Did agents explicitly respond to each other's points? Look for:
     - References to other agents by name
     - Agreement/disagreement with specific points
     - Building on previous arguments

  2. **Evidence** (0-10): Were claims backed by data, examples, or sources? Look for:
     - Statistics or data points
     - Named studies, papers, or sources
     - Concrete examples (not just abstractions)

  3. **Diversity** (0-10): Did agents genuinely disagree or just echo each other? Look for:
     - Explicit counterarguments
     - Different recommendations
     - Coverage of multiple perspectives

  4. **Context Integration** (0-10): Did agents address the user's specific situation? Look for:
     - Mentions of user's stated attributes
     - Tailored vs generic advice
     - Specific applicability statements

  5. **Actionability** (0-10): Can the user DO something with this? Look for:
     - Concrete recommendations
     - Specific next steps
     - Prioritized actions

  6. **Synthesis** (0-10): Did the final synthesis capture the discussion well? Look for:
     - References to points from multiple agents
     - Clear articulation of trade-offs
     - Coherent recommendation

  7. **Fact Checking** (0-10): Were verifiable claims checked? Look for:
     - Number of claims verified
     - Sources provided
     - Verification outcomes

  8. **Conciseness** (0-10): Did agents stay focused without redundancy? Look for:
     - Response length relative to substance
     - Minimal repetition between agents
     - Staying on topic

  ## Response Format

  Return ONLY valid JSON (no markdown, no explanation):
  {"scores":{"engagement":X,"evidence":X,"diversity":X,"context_integration":X,"actionability":X,"synthesis":X,"fact_checking":X,"conciseness":X},"overall":X,"details":{"engagement":"brief explanation","evidence":"brief explanation","diversity":"brief explanation","context_integration":"brief explanation","actionability":"brief explanation","synthesis":"brief explanation","fact_checking":"brief explanation","conciseness":"brief explanation"}}
  """

  @doc """
  Evaluates a completed deliberation.

  Returns an Evaluator struct with scores and details.
  """
  def evaluate(messages, topic, user_context \\ "Not provided") do
    Logger.info("📊 EVALUATOR: Starting evaluation for topic: #{String.slice(topic, 0, 50)}...")

    transcript = build_transcript(messages)

    prompt = @evaluation_prompt
    |> String.replace("{topic}", topic)
    |> String.replace("{user_context}", user_context || "Not provided")
    |> String.replace("{transcript}", transcript)

    case Anthropic.chat([%{role: "user", content: prompt}], model: "claude-sonnet-4-20250514") do
      {:ok, response} ->
        parse_evaluation(response)

      {:error, reason} ->
        Logger.error("📊 EVALUATOR: Failed - #{inspect(reason)}")
        %__MODULE__{status: :error, details: %{error: inspect(reason)}}
    end
  end

  defp build_transcript(messages) do
    messages
    |> Enum.map(fn msg ->
      case msg.type do
        :agent ->
          "[#{msg.agent}]: #{msg.content}"
        :user ->
          "[User]: #{msg.content}"
        :system ->
          "[System]: #{msg.content}"
        _ ->
          "[Unknown]: #{inspect(msg)}"
      end
    end)
    |> Enum.join("\n\n---\n\n")
  end

  defp parse_evaluation(response) do
    # Try to extract JSON from response (handle potential markdown wrapping)
    json_str = response
    |> String.replace(~r/```json\n?/, "")
    |> String.replace(~r/```\n?/, "")
    |> String.trim()

    case Jason.decode(json_str) do
      {:ok, data} ->
        Logger.info("📊 EVALUATOR: Complete - Overall score: #{data["overall"]}/100")

        %__MODULE__{
          scores: %{
            engagement: get_in(data, ["scores", "engagement"]) || 0,
            evidence: get_in(data, ["scores", "evidence"]) || 0,
            diversity: get_in(data, ["scores", "diversity"]) || 0,
            context_integration: get_in(data, ["scores", "context_integration"]) || 0,
            actionability: get_in(data, ["scores", "actionability"]) || 0,
            synthesis: get_in(data, ["scores", "synthesis"]) || 0,
            fact_checking: get_in(data, ["scores", "fact_checking"]) || 0,
            conciseness: get_in(data, ["scores", "conciseness"]) || 0
          },
          overall: data["overall"] || calculate_overall(data["scores"]),
          details: atomize_keys(data["details"] || %{}),
          status: :complete
        }

      {:error, reason} ->
        Logger.error("📊 EVALUATOR: JSON parse failed - #{inspect(reason)}")
        Logger.debug("📊 EVALUATOR: Raw response - #{String.slice(response, 0, 500)}")
        %__MODULE__{status: :error, details: %{error: "Failed to parse evaluation response"}}
    end
  end

  defp calculate_overall(nil), do: 0
  defp calculate_overall(scores) when is_map(scores) do
    values = Map.values(scores) |> Enum.filter(&is_number/1)
    if length(values) > 0 do
      round(Enum.sum(values) / length(values) * 10)
    else
      0
    end
  end

  # Known evaluation keys - only convert these to atoms to prevent atom table exhaustion
  @known_detail_keys ~w(engagement evidence diversity context_integration actionability synthesis fact_checking conciseness)

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = safe_to_atom(k)
      {key, v}
    end)
  end
  defp atomize_keys(other), do: other

  # Safely convert string keys to atoms, only for known keys
  defp safe_to_atom(k) when is_binary(k) do
    if k in @known_detail_keys do
      String.to_existing_atom(k)
    else
      k
    end
  rescue
    ArgumentError -> k
  end
  defp safe_to_atom(k), do: k
end
