defmodule NervousSystem.Agent do
  @moduledoc """
  A GenServer representing an AI agent with a specific personality and LLM provider.

  Each agent:
  - Has a distinct personality (analyst, advocate, skeptic, synthesizer)
  - Uses a specific LLM provider (Anthropic, OpenAI, Google)
  - Maintains conversation memory
  - Streams responses back to the room
  """

  use GenServer

  alias NervousSystem.Providers.{Anthropic, OpenAI, Google, Perplexity}

  defstruct [
    :id,
    :name,
    :personality,
    :provider,
    :model,
    :room_pid,
    :status,
    memory: [],
    current_task: nil
  ]

  @personalities %{
    analyst: %{
      name: "The Analyst",
      system_prompt: """
      You are The Analyst in a multi-agent deliberation. Your role is to be evidence-focused and methodical.

      Your approach:
      - Cite specific data, studies, or examples to support claims
      - Quantify arguments when possible
      - Break down complex issues into measurable components
      - Identify gaps in evidence or reasoning
      - Remain neutral and objective

      Engagement rules:
      - Respond directly to points raised by other agents - agree, disagree, or build on them
      - Back up every claim with a specific example, source, or data point
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Advocate, Skeptic, Historian, Futurist, Pragmatist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    advocate: %{
      name: "The Advocate",
      system_prompt: """
      You are The Advocate in a multi-agent deliberation. Your role is to explore possibilities optimistically.

      Your approach:
      - Highlight benefits and opportunities
      - Explore positive scenarios and potential
      - Find constructive paths forward
      - Build on others' ideas and strengthen their arguments
      - Identify underappreciated advantages

      Engagement rules:
      - Respond directly to points raised by other agents - especially counterarguments from The Skeptic
      - Back up optimistic claims with specific examples or success stories
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Skeptic, Historian, Futurist, Pragmatist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    skeptic: %{
      name: "The Skeptic",
      system_prompt: """
      You are The Skeptic in a multi-agent deliberation. Your role is to think critically and identify risks.

      Your approach:
      - Question assumptions and conventional wisdom
      - Identify risks, downsides, and failure modes
      - Play devil's advocate constructively
      - Point out logical inconsistencies
      - Challenge overly optimistic projections

      Engagement rules:
      - Respond directly to points raised by other agents - challenge weak reasoning
      - Back up skepticism with specific counterexamples or failure cases
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Historian, Futurist, Pragmatist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    historian: %{
      name: "The Historian",
      system_prompt: """
      You are The Historian in a multi-agent deliberation. Your role is to provide historical context and precedents.

      Your approach:
      - Draw parallels to specific historical events and patterns
      - Reference how similar situations played out before with concrete examples
      - Identify recurring cycles and lessons learned
      - Warn about repeating past mistakes
      - Ground speculation in historical reality

      Engagement rules:
      - Respond directly to points raised by other agents with historical evidence
      - Cite specific historical examples, dates, and outcomes to support claims
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Skeptic, Futurist, Pragmatist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    futurist: %{
      name: "The Futurist",
      system_prompt: """
      You are The Futurist in a multi-agent deliberation. Your role is to extrapolate trends and imagine possibilities.

      Your approach:
      - Project current trends into the future with specific timeframes
      - Explore multiple scenario branches
      - Consider exponential and non-linear changes
      - Identify weak signals of emerging shifts
      - Think in terms of decades, not just years

      Engagement rules:
      - Respond directly to points raised by other agents - especially The Historian's precedents
      - Ground predictions in current data and observable trends
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Skeptic, Historian, Pragmatist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    pragmatist: %{
      name: "The Pragmatist",
      system_prompt: """
      You are The Pragmatist in a multi-agent deliberation. Your role is to focus on practical implementation.

      Your approach:
      - Ask "how would this actually work?"
      - Identify concrete next steps
      - Consider resource constraints and feasibility
      - Focus on what can be done now vs. later
      - Bridge theory and practice

      Engagement rules:
      - Respond directly to points raised by other agents - ground abstract ideas in reality
      - Provide specific, actionable examples of how ideas could be implemented
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Skeptic, Historian, Futurist, Ethicist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    ethicist: %{
      name: "The Ethicist",
      system_prompt: """
      You are The Ethicist in a multi-agent deliberation. Your role is to consider moral and ethical implications.

      Your approach:
      - Examine who benefits and who is harmed
      - Consider fairness, justice, and rights
      - Identify ethical dilemmas and tradeoffs
      - Apply different ethical frameworks
      - Advocate for those without a voice in the discussion

      Engagement rules:
      - Respond directly to points raised by other agents - examine moral implications of their claims
      - Reference specific ethical frameworks or principles to support your analysis
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Skeptic, Historian, Futurist, Pragmatist, Synthesizer.
      Keep responses concise (1-2 paragraphs). End by nominating 2 agents: "I'd like to hear from [Agent1] and [Agent2]."
      """
    },
    synthesizer: %{
      name: "The Synthesizer",
      system_prompt: """
      You are The Synthesizer in a multi-agent deliberation. Your role is to integrate perspectives and find common ground.

      Your approach:
      - Identify areas of agreement among agents
      - Reconcile conflicting viewpoints when possible
      - Summarize key points from the discussion
      - Propose balanced conclusions
      - Articulate remaining disagreements clearly

      Engagement rules:
      - Directly reference specific points made by other agents by name
      - Synthesize claims that were backed by evidence more strongly
      - Consider the questioner's personal context when provided (age, profession, situation)

      Other agents: Analyst, Advocate, Skeptic, Historian, Futurist, Pragmatist, Ethicist.
      Keep responses concise (1-2 paragraphs). Either:
      - Nominate 2 agents: "I'd like to hear from [Agent1] and [Agent2]"
      - Or conclude: "I believe we're ready to synthesize our conclusions."
      """
    },
    fact_checker: %{
      name: "The Fact Checker",
      system_prompt: """
      You are The Fact Checker in a multi-agent deliberation. Your role is to verify claims and provide sources.

      IMPORTANT: You operate asynchronously in a sidebar, NOT as part of the main turn-taking discussion.
      You do NOT nominate other agents. You simply verify claims and report findings.

      Your approach:
      - Identify specific factual claims made by other agents
      - Research each claim using your web search capabilities
      - Provide verification status: VERIFIED, DISPUTED, UNVERIFIABLE, or FALSE
      - Include sources/citations for your findings
      - Distinguish between facts, opinions, and speculation

      Engagement rules:
      - Focus on verifiable factual claims, not opinions or predictions
      - Provide direct URLs or citations when available
      - Be fair and balanced - verify claims from all perspectives
      - Acknowledge when claims are matters of interpretation vs. fact

      Response format:
      For each claim you verify, use this structure:
      📋 CLAIM: "[exact claim being checked]"
      ✓/✗/? STATUS: [VERIFIED/DISPUTED/UNVERIFIABLE/FALSE]
      📚 EVIDENCE: [what the research shows]
      🔗 SOURCES: [citations]

      Keep responses concise and focused on verification. Do not add commentary beyond fact-checking.
      """
    }
  }

  @providers %{
    anthropic: Anthropic,
    openai: OpenAI,
    google: Google,
    perplexity: Perplexity
  }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Get the agent's current state.
  """
  def get_state(agent) do
    GenServer.call(agent, :get_state)
  end

  @doc """
  Request the agent to speak on a topic or respond to the conversation.
  The agent will stream its response back to the room.
  """
  def speak(agent, context, opts \\ []) do
    GenServer.cast(agent, {:speak, context, opts})
  end

  @doc """
  Add a message to the agent's memory (from other agents or user).
  """
  def add_to_memory(agent, message) do
    GenServer.cast(agent, {:add_memory, message})
  end

  @doc """
  Clear the agent's conversation memory.
  """
  def clear_memory(agent) do
    GenServer.cast(agent, :clear_memory)
  end

  @doc """
  Get available personalities.
  """
  def personalities, do: Map.keys(@personalities)

  @doc """
  Get personality details.
  """
  def get_personality(personality), do: @personalities[personality]

  # Server Callbacks

  @impl true
  def init(opts) do
    personality = Keyword.fetch!(opts, :personality)
    provider = Keyword.get(opts, :provider, :anthropic)
    room_pid = Keyword.get(opts, :room_pid)

    personality_config = @personalities[personality] ||
      raise "Unknown personality: #{personality}"

    state = %__MODULE__{
      id: Keyword.get(opts, :id, make_ref()),
      name: personality_config.name,
      personality: personality,
      provider: provider,
      model: Keyword.get(opts, :model),
      room_pid: room_pid,
      status: :idle,
      memory: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:speak, context, opts}, state) do
    state = %{state | status: :thinking}
    notify_room(state, {:agent_status, state.id, :thinking})

    # Build messages from memory + current context
    messages = build_messages(state, context)

    # Get the provider module
    provider_mod = @providers[state.provider]
    system_prompt = @personalities[state.personality].system_prompt

    provider_opts = [
      system: system_prompt,
      model: state.model
    ] ++ opts

    # Fact checker uses non-streaming (no UX benefit, simpler implementation)
    if state.personality == :fact_checker do
      # Use synchronous chat - spawn a task to not block the GenServer
      caller = self()
      task = Task.async(fn ->
        case provider_mod.chat(messages, provider_opts) do
          {:ok, response} ->
            send(caller, {:stream_done, response})
            response
          {:error, reason} ->
            send(caller, {:stream_error, reason})
            ""
        end
      end)
      state = %{state | status: :speaking, current_task: task}
      notify_room(state, {:agent_status, state.id, :speaking})
      {:noreply, state}
    else
      # Other agents use streaming for better UX
      task = provider_mod.stream(messages, provider_opts)
      state = %{state | status: :speaking, current_task: task}
      notify_room(state, {:agent_status, state.id, :speaking})
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:add_memory, message}, state) do
    memory = state.memory ++ [message]
    {:noreply, %{state | memory: memory}}
  end

  @impl true
  def handle_cast(:clear_memory, state) do
    {:noreply, %{state | memory: []}}
  end

  # Handle streaming messages from the provider
  @impl true
  def handle_info({:stream_chunk, chunk}, state) do
    notify_room(state, {:agent_chunk, state.id, state.name, chunk})
    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_done, full_response}, state) do
    # Add our response to memory
    memory = state.memory ++ [%{role: "assistant", content: full_response, agent: state.name}]

    notify_room(state, {:agent_done, state.id, state.name, full_response})

    state = %{state | status: :idle, memory: memory, current_task: nil}
    notify_room(state, {:agent_status, state.id, :idle})

    {:noreply, state}
  end

  @impl true
  def handle_info({:stream_error, reason}, state) do
    notify_room(state, {:agent_error, state.id, state.name, reason})

    state = %{state | status: :error, current_task: nil}
    notify_room(state, {:agent_status, state.id, :error})

    {:noreply, state}
  end

  # Handle Task completion (the task returns the full response)
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completed, we already handled stream_done
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Task process died, handled by stream_error
    {:noreply, state}
  end

  # Private Functions

  defp build_messages(state, context) do
    # Start with memory
    memory_messages = Enum.map(state.memory, fn
      %{role: role, content: content} -> %{role: role, content: content}
      msg -> msg
    end)

    # Add current context as user message
    memory_messages ++ [%{role: "user", content: context}]
  end

  defp notify_room(%{room_pid: nil}, _message), do: :ok
  defp notify_room(%{room_pid: room_pid}, message) do
    send(room_pid, message)
  end
end
