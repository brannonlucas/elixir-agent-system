defmodule NervousSystem.Room do
  @moduledoc """
  GenServer that orchestrates a multi-agent deliberation.

  The Room manages:
  - Discussion phases (framework → discussion → synthesis)
  - Turn-taking via the "facilitated roundtable" pattern
  - Agent lifecycle and communication
  - PubSub broadcasting for LiveView updates
  """

  use GenServer
  require Logger

  alias NervousSystem.Agent
  alias NervousSystem.Evaluator
  alias Phoenix.PubSub

  @pubsub NervousSystem.PubSub

  defstruct [
    :id,
    :topic,
    :phase,
    :current_speaker,
    :nominated_respondents,
    agents: %{},
    messages: [],
    framework: nil,
    awaiting_responses: [],
    turn_count: 0,
    stopped: false,
    fact_check_queue: [],  # [{id, source_agent, claims, status, verdict, result}]
    pending_synthesis: false,  # True when waiting for fact checks before synthesis
    evaluation: nil,  # Stores quality evaluation after synthesis
    agent_turn_counts: %{}  # Track turns per agent {personality => count}
  ]

  @max_discussion_turns 18  # 2 rounds per agent before forced conclusion (9 agents)
  @max_framework_turns 4    # Quick framework establishment
  @max_agent_turns 3        # Maximum turns any single agent can take

  # Client API

  def start_link(opts) do
    id = Keyword.get(opts, :id, generate_id())
    # Pass the generated ID to init so state.id matches the registration
    GenServer.start_link(__MODULE__, Keyword.put(opts, :id, id), name: via_tuple(id))
  end

  def via_tuple(id), do: {:via, Registry, {NervousSystem.RoomRegistry, id}}

  @doc """
  Start a new deliberation on a topic.
  """
  def start_deliberation(room, topic) do
    GenServer.call(room, {:start_deliberation, topic})
  end

  @doc """
  User interjects with a comment or question.
  """
  def user_interject(room, message) do
    GenServer.cast(room, {:user_interject, message})
  end

  @doc """
  Emergency stop - immediately halt all discussion.
  """
  def stop_deliberation(room) do
    GenServer.call(room, :stop_deliberation)
  end

  @doc """
  Get the current room state.
  """
  def get_state(room) do
    GenServer.call(room, :get_state)
  end

  @doc """
  Subscribe to room updates.
  """
  def subscribe(room_id) do
    PubSub.subscribe(@pubsub, topic(room_id))
  end

  defp topic(room_id), do: "room:#{room_id}"

  # Server Callbacks

  @impl true
  def init(opts) do
    # ID is passed from start_link to ensure it matches the registration
    id = Keyword.fetch!(opts, :id)

    # Create agents with different personalities and providers
    agents = create_agents(self())

    state = %__MODULE__{
      id: id,
      phase: nil,
      agents: agents
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_deliberation, topic}, _from, state) do
    # Initialize deliberation
    state = %{state |
      topic: topic,
      phase: :framework,
      messages: [],
      framework: nil,
      turn_count: 0,
      agent_turn_counts: %{}
    }

    broadcast(state, {:phase_changed, :framework})
    broadcast(state, {:topic_set, topic})

    # Start with the Analyst proposing a framework
    analyst = find_agent_by_personality(state.agents, :analyst)
    context = """
    [TURN 1/#{@max_framework_turns}]

    We are beginning a deliberation on the topic: "#{topic}"

    As the first speaker, please propose a framework for how we should approach this discussion
    and reach conclusions. Consider what criteria we should use to evaluate arguments,
    what evidence we should consider, and how we should structure our debate.

    After your proposal, nominate two other agents to respond.
    """

    Agent.speak(analyst.pid, context)

    state = %{state |
      current_speaker: :analyst,
      turn_count: 1,
      agent_turn_counts: Map.put(state.agent_turn_counts, :analyst, 1)
    }
    broadcast(state, {:agent_speaking, :analyst, "The Analyst"})
    broadcast(state, {:turn_count_updated, 1})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    public_state = %{
      id: state.id,
      topic: state.topic,
      phase: state.phase,
      current_speaker: state.current_speaker,
      messages: state.messages,
      framework: state.framework,
      stopped: state.stopped,
      turn_count: state.turn_count,
      agents: Enum.map(state.agents, fn {personality, agent} ->
        %{personality: personality, name: agent.name, status: agent.status}
      end)
    }
    {:reply, public_state, state}
  end

  @impl true
  def handle_call(:stop_deliberation, _from, state) do
    state = %{state | stopped: true, phase: :stopped}
    broadcast(state, {:deliberation_stopped, "Discussion stopped by user"})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:user_interject, _message}, %{stopped: true} = state) do
    # Ignore user messages when stopped
    {:noreply, state}
  end

  @impl true
  def handle_cast({:user_interject, message}, state) do
    # Add user message to history
    user_msg = %{
      type: :user,
      content: message,
      timestamp: DateTime.utc_now()
    }
    state = %{state | messages: state.messages ++ [user_msg]}
    broadcast(state, {:user_message, message})

    # Have the current speaker (or synthesizer) respond to the interjection
    responder = if state.current_speaker do
      find_agent_by_personality(state.agents, state.current_speaker)
    else
      find_agent_by_personality(state.agents, :synthesizer)
    end

    max_turns = if state.phase == :framework, do: @max_framework_turns, else: @max_discussion_turns
    context = """
    [TURN #{state.turn_count}/#{max_turns}]

    A user has interjected with the following:

    User: "#{message}"

    Please acknowledge and respond to this point, then continue the discussion
    by nominating which agents should speak next.
    """

    # Add to all agents' memory
    add_to_all_memories(state.agents, %{role: "user", content: "User interjection: #{message}"})

    Agent.speak(responder.pid, context)

    {:noreply, state}
  end

  # Handle agent streaming chunks
  @impl true
  def handle_info({:agent_chunk, _agent_id, agent_name, chunk}, state) do
    broadcast(state, {:agent_chunk, agent_name, chunk})
    {:noreply, state}
  end

  # Handle agent completion
  @impl true
  def handle_info({:agent_done, _agent_id, _agent_name, _full_response}, %{stopped: true} = state) do
    # Ignore agent responses when stopped
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_done, _agent_id, agent_name, full_response}, state) do
    Logger.info("✅ AGENT DONE: #{agent_name} | phase: #{state.phase} | turn: #{state.turn_count} | current_speaker: #{state.current_speaker} | awaiting: #{inspect(state.awaiting_responses)}")

    # Add to message history
    agent_msg = %{
      type: :agent,
      agent: agent_name,
      personality: state.current_speaker,
      content: full_response,
      timestamp: DateTime.utc_now()
    }
    state = %{state | messages: state.messages ++ [agent_msg]}
    broadcast(state, {:agent_complete, agent_name, full_response})

    # Add to all other agents' memory
    memory_msg = %{role: "assistant", content: "[#{agent_name}]: #{full_response}"}
    add_to_all_memories(state.agents, memory_msg)

    # Real-time claim detection - trigger Fact Checker in parallel
    # Don't fact-check the Fact Checker's own responses
    # Check by agent_name since Fact Checker runs async and isn't the current_speaker
    is_fact_checker = agent_name == "The Fact Checker"

    # Fact Checker runs async in sidebar - should NOT affect turn count or nominations
    if is_fact_checker do
      Logger.info("🔬 FACT CHECKER COMPLETE: Skipping nomination/turn processing")
      state = complete_fact_check(state, full_response)
      {:noreply, state}
    else
      # Other agents - detect claims and queue fact checks
      claims = detect_claims(full_response)
      state = if length(claims) > 0 do
        queue_fact_check(state, agent_name, claims)
      else
        state
      end

      # Parse for nominations
    nominations = parse_nominations(full_response, state.agents)
    Logger.debug("🔍 PARSED NOMINATIONS: #{inspect(nominations)}")

    state = cond do
      # Synthesis phase complete - stop the deliberation and trigger evaluation
      state.phase == :synthesis ->
        Logger.info("🏁 BRANCH: Synthesis complete → stopping")
        broadcast(state, {:deliberation_stopped, "Synthesis complete. Discussion concluded."})

        # Trigger async evaluation under TaskSupervisor for fault tolerance
        room_id = state.id
        messages = state.messages
        topic = state.topic
        Task.Supervisor.start_child(NervousSystem.TaskSupervisor, fn ->
          Logger.info("📊 EVALUATOR: Starting async evaluation...")
          try do
            evaluation = Evaluator.evaluate(messages, topic)
            PubSub.broadcast(@pubsub, "room:#{room_id}", {:evaluation_complete, evaluation})
          rescue
            e ->
              Logger.error("📊 EVALUATOR: Failed with error: #{inspect(e)}")
              error_evaluation = %NervousSystem.Evaluator{
                status: :error,
                details: %{error: "Evaluation failed: #{Exception.message(e)}"}
              }
              PubSub.broadcast(@pubsub, "room:#{room_id}", {:evaluation_complete, error_evaluation})
          end
        end)

        %{state | stopped: true, phase: :stopped}

      # Framework phase - hit turn limit, force move to discussion
      state.phase == :framework and state.turn_count >= @max_framework_turns ->
        Logger.info("🏁 BRANCH: Framework turn limit → discussion")
        handle_framework_complete(state)

      # Discussion phase - hit turn limit, force synthesis
      state.phase == :discussion and state.turn_count >= @max_discussion_turns ->
        Logger.info("🏁 BRANCH: Discussion turn limit (#{state.turn_count}) → synthesis")
        broadcast(state, {:turn_limit_reached, state.turn_count})
        handle_move_to_synthesis(state)

      # Check for synthesis trigger
      synthesis_requested?(full_response) ->
        Logger.info("🏁 BRANCH: Synthesis requested → synthesis")
        handle_move_to_synthesis(state)

      # Process awaiting responses FIRST (the second nominated agent from previous turn)
      length(state.awaiting_responses) > 0 ->
        [next | rest] = state.awaiting_responses
        Logger.info("🏁 BRANCH: Awaiting response → #{next}")
        handle_awaiting_response(state, next, rest)

      # Normal turn handling with multiple nominations
      length(nominations) >= 2 ->
        [first, second | _] = nominations
        Logger.info("🏁 BRANCH: Multiple nominations → #{inspect([first, second])}")
        handle_nominations(state, [first, second])

      # Single nomination
      length(nominations) == 1 ->
        Logger.info("🏁 BRANCH: Single nomination → #{inspect(nominations)}")
        handle_nominations(state, nominations)

      # No clear nomination, rotate
      true ->
        Logger.info("🏁 BRANCH: No nomination → rotate")
        handle_no_nomination(state)
    end

      {:noreply, state}
    end  # end else (non-fact-checker agents)
  end

  @impl true
  def handle_info({:agent_status, _agent_id, _status}, state) do
    # Could update agent status tracking here
    {:noreply, state}
  end

  @impl true
  def handle_info({:agent_error, _agent_id, agent_name, reason}, state) do
    broadcast(state, {:agent_error, agent_name, reason})
    {:noreply, state}
  end

  # Private Functions

  defp create_agents(room_pid) do
    # Create 9 agents with rotating providers for diversity
    # Fact Checker uses Perplexity for web research capabilities
    # Synthesizer and Ethicist use Opus 4.5 for more nuanced reasoning
    configs = [
      {:analyst, :anthropic, nil},
      {:advocate, :openai, nil},
      {:skeptic, :google, nil},
      {:historian, :anthropic, nil},
      {:futurist, :openai, nil},
      {:pragmatist, :google, nil},
      {:ethicist, :anthropic, "claude-opus-4-20250514"},
      {:synthesizer, :anthropic, "claude-opus-4-20250514"},
      {:fact_checker, :perplexity, nil}
    ]

    configs
    |> Enum.map(fn {personality, provider, model} ->
      opts = [
        personality: personality,
        provider: provider,
        room_pid: room_pid
      ]
      opts = if model, do: Keyword.put(opts, :model, model), else: opts

      # Start agents under the AgentSupervisor for fault tolerance
      {:ok, pid} = DynamicSupervisor.start_child(
        NervousSystem.AgentSupervisor,
        {Agent, opts}
      )

      agent_state = Agent.get_state(pid)
      {personality, %{pid: pid, name: agent_state.name, status: :idle}}
    end)
    |> Map.new()
  end

  defp find_agent_by_personality(agents, personality) do
    case agents[personality] do
      nil -> nil
      agent -> agent
    end
  end

  # Check if an agent can still speak (hasn't hit max turns)
  defp agent_can_speak?(state, personality) do
    # Synthesizer is exempt - they always need to be able to synthesize
    personality == :synthesizer or
      Map.get(state.agent_turn_counts, personality, 0) < @max_agent_turns
  end

  # Increment turn count for an agent
  defp increment_agent_turns(state, personality) do
    current = Map.get(state.agent_turn_counts, personality, 0)
    %{state | agent_turn_counts: Map.put(state.agent_turn_counts, personality, current + 1)}
  end

  # Filter list of personalities to those who can still speak
  defp filter_available_agents(state, personalities) do
    Enum.filter(personalities, &agent_can_speak?(state, &1))
  end

  # Get next available agent in rotation (skipping those at max turns)
  defp next_available_agent(state) do
    # Don't include fact_checker in rotation - they run async
    personalities = [:analyst, :advocate, :skeptic, :historian, :futurist, :pragmatist, :ethicist, :synthesizer]
    current_index = Enum.find_index(personalities, &(&1 == state.current_speaker)) || 0

    # Try each personality starting from current+1, wrapping around
    Enum.find(0..7, fn offset ->
      personality = Enum.at(personalities, rem(current_index + 1 + offset, 8))
      agent_can_speak?(state, personality)
    end)
    |> case do
      nil -> :synthesizer  # Fallback to synthesizer if everyone is maxed
      offset ->
        Enum.at(personalities, rem(current_index + 1 + offset, 8))
    end
  end

  defp parse_nominations(response, agents) do
    # Look for patterns like "I'd like to hear from X and Y"
    response_lower = String.downcase(response)

    Map.keys(agents)
    |> Enum.filter(fn personality ->
      name = Atom.to_string(personality)
      String.contains?(response_lower, name) and
        (String.contains?(response_lower, "hear from") or
         String.contains?(response_lower, "like to hear") or
         String.contains?(response_lower, "thoughts from") or
         String.contains?(response_lower, "turn to"))
    end)
  end

  defp synthesis_requested?(response) do
    response_lower = String.downcase(response)
    String.contains?(response_lower, "ready to synthesize") or
      String.contains?(response_lower, "move to conclusion") or
      String.contains?(response_lower, "ready to conclude")
  end

  defp handle_framework_complete(state) do
    # After framework discussion, move to main discussion
    broadcast(state, {:phase_changed, :discussion})

    # Have synthesizer summarize the agreed framework
    synthesizer = find_agent_by_personality(state.agents, :synthesizer)
    context = """
    The framework discussion is complete. Please synthesize the key points from
    all agents into a shared framework we'll use for this deliberation.

    Then, kick off the main discussion on the topic: "#{state.topic}"
    by sharing your initial thoughts and nominating which agents should speak next.
    """

    Agent.speak(synthesizer.pid, context)

    # Start at turn 1 so Synthesizer kickoff counts as turn 1
    # Discussion runs turns 1-18 = 18 total turns
    broadcast(state, {:turn_count_updated, 1})

    %{state |
      phase: :discussion,
      current_speaker: :synthesizer,
      turn_count: 1
    }
  end

  defp handle_move_to_synthesis(state) do
    # Check if there are pending fact checks
    if has_pending_fact_checks?(state) do
      # Wait for fact checks to complete before synthesis
      pending_count = Enum.count(state.fact_check_queue, &(&1.status == :checking))
      broadcast(state, {:waiting_for_fact_checks, pending_count})
      %{state | pending_synthesis: true}
    else
      # No pending fact checks - proceed immediately
      do_synthesis(state)
    end
  end

  defp do_synthesis(state) do
    broadcast(state, {:phase_changed, :synthesis})

    fact_check_summary = build_fact_check_summary(state)

    synthesizer = find_agent_by_personality(state.agents, :synthesizer)
    context = """
    [SYNTHESIS PHASE - Discussion complete after #{state.turn_count} turns]

    The discussion phase is complete. Please provide a comprehensive synthesis:

    1. Summarize the key points and arguments made
    2. Identify areas of agreement among agents
    3. Clearly articulate any remaining disagreements
    4. Propose conclusions based on the framework we established

    IMPORTANT: Consider the following fact-check results when forming your synthesis.
    Claims that were disputed or false should be noted, and conclusions should not rely on unverified claims.

    #{fact_check_summary}

    After your synthesis, the deliberation will conclude.
    """

    Agent.speak(synthesizer.pid, context)

    %{state |
      phase: :synthesis,
      current_speaker: :synthesizer,
      pending_synthesis: false
    }
  end

  defp handle_nominations(state, _nominated_personalities) when state.turn_count >= @max_discussion_turns do
    # Hard stop - don't allow any more nominations
    broadcast(state, {:turn_limit_reached, state.turn_count})
    handle_move_to_synthesis(state)
  end

  defp handle_nominations(state, nominated_personalities) do
    # Filter to only agents who haven't hit their turn limit
    available = filter_available_agents(state, nominated_personalities)

    case available do
      [] ->
        # All nominated agents at max turns - find next available
        Logger.info("📍 All nominated agents at max turns, finding next available")
        next = next_available_agent(state)
        handle_nominations(state, [next])

      [first | rest] ->
        next_turn = state.turn_count + 1
        agent_turns = Map.get(state.agent_turn_counts, first, 0) + 1

        Logger.info("📍 NOMINATION: #{first} (turn #{agent_turns}/#{@max_agent_turns}) | global turn #{state.turn_count} → #{next_turn} | awaiting: #{inspect(rest)}")

        first_agent = find_agent_by_personality(state.agents, first)
        if first_agent do
          context = """
          [TURN #{next_turn}/#{@max_discussion_turns}]

          You've been nominated to respond to the previous point in our deliberation
          on "#{state.topic}".

          Please share your perspective, then nominate which agents should speak next.
          """
          Logger.debug("📤 CONTEXT to #{first}: #{String.slice(context, 0, 80)}...")
          Agent.speak(first_agent.pid, context)
        end

        # Queue the rest (already filtered to available)
        state = state
        |> increment_agent_turns(first)
        |> Map.put(:current_speaker, first)
        |> Map.put(:awaiting_responses, rest)
        |> Map.put(:turn_count, next_turn)

        broadcast(state, {:agent_speaking, first, first_agent.name})
        broadcast(state, {:turn_count_updated, next_turn})
        state
    end
  end

  # Handle the second (or subsequent) nominated agent from a previous nomination
  defp handle_awaiting_response(state, personality, remaining) do
    # Check if this agent can still speak
    if agent_can_speak?(state, personality) do
      next_turn = state.turn_count + 1
      agent_turns = Map.get(state.agent_turn_counts, personality, 0) + 1
      Logger.info("📍 AWAITING RESPONSE: #{personality} (turn #{agent_turns}/#{@max_agent_turns}) | global turn #{state.turn_count} → #{next_turn} | remaining: #{inspect(remaining)}")

      agent = find_agent_by_personality(state.agents, personality)
      if agent do
        context = """
        [TURN #{next_turn}/#{@max_discussion_turns}]

        You were nominated alongside another agent to respond. Now it's your turn.
        Topic: "#{state.topic}"

        Please share your perspective on the discussion so far, then nominate which agents should speak next.
        """
        Agent.speak(agent.pid, context)
      end

      state = state
      |> increment_agent_turns(personality)
      |> Map.put(:current_speaker, personality)
      |> Map.put(:awaiting_responses, remaining)
      |> Map.put(:turn_count, next_turn)

      broadcast(state, {:agent_speaking, personality, agent.name})
      broadcast(state, {:turn_count_updated, next_turn})
      state
    else
      # Agent at max turns - skip to next in remaining or find available
      Logger.info("📍 SKIPPING #{personality} (at max #{@max_agent_turns} turns)")
      case filter_available_agents(state, remaining) do
        [] ->
          # No more available in queue - find next available agent
          next = next_available_agent(state)
          handle_nominations(state, [next])
        [next | rest] ->
          handle_awaiting_response(state, next, rest)
      end
    end
  end

  defp handle_no_nomination(state) do
    # Find next available agent (skips those at max turns)
    next_personality = next_available_agent(state)
    Logger.info("📍 NO NOMINATION: rotating to #{next_personality}")
    handle_nominations(state, [next_personality])
  end

  defp add_to_all_memories(agents, message) do
    agents
    |> Map.values()
    |> Enum.each(fn agent ->
      Agent.add_to_memory(agent.pid, message)
    end)
  end

  defp broadcast(state, message) do
    PubSub.broadcast(@pubsub, topic(state.id), message)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  # Claim Detection and Fact-Checking

  @claim_patterns [
    # Statistics and percentages
    ~r/(\d+(?:\.\d+)?)\s*(?:%|percent)/i,
    # Year references with claims
    ~r/(?:in|since|by|around)\s+(\d{4})/i,
    # Studies and research citations
    ~r/(?:studies?\s+(?:show|indicate|suggest|found|reveal)|research\s+(?:shows?|indicates?|suggests?|found|reveals?))/i,
    # According to sources
    ~r/according\s+to\s+(?:a\s+)?(?:recent\s+)?(?:\w+\s+){1,3}/i,
    # Numerical claims
    ~r/(?:approximately|about|roughly|nearly|over|more than|less than)\s+(\d+(?:,\d{3})*(?:\.\d+)?)\s+(?:million|billion|thousand|people|users|companies)/i,
    # Definitive factual statements
    ~r/(?:it\s+is\s+(?:a\s+)?fact\s+that|the\s+fact\s+is|factually|in\s+fact)/i,
    # Historical claims
    ~r/(?:historically|in\s+history|throughout\s+history)/i,
    # Economic/market claims
    ~r/(?:market\s+(?:share|cap|value)|GDP|revenue|valuation)\s+(?:of|is|was|reached)\s+\$?[\d,.]+/i
  ]

  defp detect_claims(response) do
    # Extract sentences that match claim patterns
    sentences = String.split(response, ~r/(?<=[.!?])\s+/, trim: true)

    sentences
    |> Enum.filter(fn sentence ->
      Enum.any?(@claim_patterns, fn pattern ->
        Regex.match?(pattern, sentence)
      end)
    end)
    |> Enum.take(3)  # Limit to 3 claims per response to avoid overload
  end

  defp queue_fact_check(state, source_agent, claims) do
    fact_checker = find_agent_by_personality(state.agents, :fact_checker)

    if fact_checker do
      # Generate unique ID for this fact-check request
      check_id = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
      Logger.debug("🔍 QUEUE_FACT_CHECK: Creating item #{check_id} for #{source_agent} with #{length(claims)} claims")

      claims_text = claims |> Enum.with_index(1) |> Enum.map(fn {claim, idx} ->
        "#{idx}. \"#{String.trim(claim)}\""
      end) |> Enum.join("\n")

      context = """
      [FACT CHECK REQUEST #{check_id} - Do not nominate anyone after this]

      #{source_agent} made the following claims that need verification:

      #{claims_text}

      Please verify each claim using web search. For each claim, provide:
      - VERIFIED ✓ / DISPUTED ⚠️ / FALSE ✗ / UNVERIFIABLE ?
      - Brief evidence summary
      - Source URL if available

      Keep your response concise and focused only on verification.
      """

      # Add to queue
      queue_item = %{
        id: check_id,
        source_agent: source_agent,
        claims: claims,
        status: :checking,
        timestamp: DateTime.utc_now(),
        result: nil,
        verdict: nil
      }

      new_queue = state.fact_check_queue ++ [queue_item]

      # Broadcast queue update
      Logger.debug("🔍 QUEUE_FACT_CHECK: Broadcasting queued item #{check_id}, queue size now #{length(new_queue)}")
      broadcast(state, {:fact_check_queued, queue_item})

      # Trigger the fact checker (this runs async via the agent's Task)
      Agent.speak(fact_checker.pid, context)

      %{state | fact_check_queue: new_queue}
    else
      state
    end
  end

  defp complete_fact_check(state, response) do
    # Find the oldest pending/checking item and mark it complete
    queue_statuses = Enum.map(state.fact_check_queue, &(&1.status))
    Logger.debug("🔍 COMPLETE_FACT_CHECK: Queue has #{length(state.fact_check_queue)} items with statuses: #{inspect(queue_statuses)}")

    case Enum.find_index(state.fact_check_queue, &(&1.status == :checking)) do
      nil ->
        Logger.warning("🔍 COMPLETE_FACT_CHECK: No :checking item found in queue!")
        state

      idx ->
        {completed_item, rest} = List.pop_at(state.fact_check_queue, idx)
        Logger.debug("🔍 COMPLETE_FACT_CHECK: Raw response (first 500 chars): #{String.slice(response, 0, 500)}")
        verdict = parse_verdict(response)
        Logger.debug("🔍 COMPLETE_FACT_CHECK: Completing item #{completed_item.id} with verdict #{verdict}")
        completed_item = %{completed_item | status: :complete, result: response, verdict: verdict}

        # Keep completed items for display (limit to last 10)
        completed_queue = (rest ++ [completed_item]) |> Enum.take(-10)

        Logger.debug("🔍 COMPLETE_FACT_CHECK: Broadcasting completion for #{completed_item.id}")
        broadcast(state, {:fact_check_complete, completed_item})

        state = %{state | fact_check_queue: completed_queue}

        # Check if we were waiting for fact checks before synthesis
        pending_checks = Enum.count(completed_queue, &(&1.status == :checking))
        if state.pending_synthesis and pending_checks == 0 do
          # All fact checks done - proceed with synthesis
          do_synthesis(state)
        else
          state
        end
    end
  end

  # Parse verdict from fact-check response
  # Looks for patterns like "VERIFIED", "DISPUTED", etc. in various formats
  defp parse_verdict(response) do
    response_upper = String.upcase(response)

    cond do
      # Verified patterns
      String.contains?(response_upper, "VERIFIED ✓") or
      String.contains?(response_upper, "VERIFIED✓") or
      String.contains?(response_upper, "✓ VERIFIED") or
      String.contains?(response_upper, "STATUS: VERIFIED") or
      String.contains?(response_upper, "**VERIFIED**") or
      Regex.match?(~r/\bVERIFIED\b/, response_upper) ->
        :verified

      # Partial patterns
      String.contains?(response_upper, "PARTIALLY") or
      String.contains?(response_upper, "PARTIAL") or
      String.contains?(response_upper, "⚠") ->
        :partial

      # Disputed patterns
      String.contains?(response_upper, "DISPUTED ⚠") or
      String.contains?(response_upper, "DISPUTED⚠") or
      String.contains?(response_upper, "⚠️ DISPUTED") or
      String.contains?(response_upper, "STATUS: DISPUTED") or
      String.contains?(response_upper, "**DISPUTED**") or
      Regex.match?(~r/\bDISPUTED\b/, response_upper) ->
        :disputed

      # False patterns
      String.contains?(response_upper, "FALSE ✗") or
      String.contains?(response_upper, "FALSE✗") or
      String.contains?(response_upper, "✗ FALSE") or
      String.contains?(response_upper, "STATUS: FALSE") or
      String.contains?(response_upper, "**FALSE**") or
      Regex.match?(~r/\bFALSE\b/, response_upper) ->
        :false

      # Unverifiable patterns
      String.contains?(response_upper, "UNVERIFIABLE") or
      String.contains?(response_upper, "CANNOT BE VERIFIED") or
      String.contains?(response_upper, "UNABLE TO VERIFY") or
      String.contains?(response_upper, "NOT VERIFIABLE") ->
        :unverifiable

      true ->
        :unknown
    end
  end

  # Check if any fact checks are still pending
  defp has_pending_fact_checks?(state) do
    Enum.any?(state.fact_check_queue, &(&1.status == :checking))
  end

  # Build fact-check summary for synthesis
  defp build_fact_check_summary(state) do
    completed = Enum.filter(state.fact_check_queue, &(&1.status == :complete))

    if length(completed) == 0 do
      "No claims were fact-checked during this discussion."
    else
      summary = completed
      |> Enum.map(fn item ->
        verdict_str = case item.verdict do
          :verified -> "✓ VERIFIED"
          :partial -> "⚠ PARTIALLY VERIFIED"
          :disputed -> "✗ DISPUTED"
          :false -> "✗ FALSE"
          :unverifiable -> "? UNVERIFIABLE"
          _ -> "? UNKNOWN"
        end
        claim_preview = item.claims |> Enum.at(0, "") |> String.slice(0..80)
        "- #{verdict_str}: \"#{claim_preview}...\" (from #{item.source_agent})"
      end)
      |> Enum.join("\n")

      """
      FACT-CHECK SUMMARY:
      #{summary}
      """
    end
  end
end
