defmodule NervousSystemWeb.RoomLive do
  @moduledoc """
  LiveView for multi-agent deliberation rooms.

  Displays real-time streaming responses from multiple AI agents
  as they discuss a topic using the facilitated roundtable pattern.
  """

  use NervousSystemWeb, :live_view

  alias NervousSystem.Room

  @impl true
  def mount(params, _session, socket) do
    socket = case params do
      %{"id" => room_id} ->
        # Joining existing room - check if it exists first
        case Registry.lookup(NervousSystem.RoomRegistry, room_id) do
          [{_pid, _}] ->
            # Room exists
            if connected?(socket), do: Room.subscribe(room_id)
            room_state = Room.get_state(Room.via_tuple(room_id))

            socket
            |> assign(:room_id, room_id)
            |> assign(:room, room_state)
            |> assign(:messages, room_state.messages)
            |> assign(:streaming_message, nil)
            |> assign(:topic_input, "")
            |> assign(:user_input, "")
            |> assign(:stopped, room_state[:stopped] || false)
            |> assign(:turn_count, room_state[:turn_count] || 0)
            |> assign(:fact_check_queue, room_state[:fact_check_queue] || [])
            |> assign(:evaluation, nil)
            |> assign(:page_title, "Room #{room_id}")

          [] ->
            # Room doesn't exist - redirect to home with error
            socket
            |> assign(:room_id, nil)
            |> assign(:room, nil)
            |> assign(:messages, [])
            |> assign(:streaming_message, nil)
            |> assign(:topic_input, "")
            |> assign(:user_input, "")
            |> assign(:stopped, false)
            |> assign(:turn_count, 0)
            |> assign(:fact_check_queue, [])
            |> assign(:evaluation, nil)
            |> assign(:page_title, "New Deliberation")
            |> assign(:error, "Room not found. It may have expired. Start a new deliberation.")
            |> push_navigate(to: ~p"/")
        end

      _ ->
        # New room form
        socket
        |> assign(:room_id, nil)
        |> assign(:room, nil)
        |> assign(:messages, [])
        |> assign(:streaming_message, nil)
        |> assign(:topic_input, "")
        |> assign(:user_input, "")
        |> assign(:stopped, false)
        |> assign(:turn_count, 0)
        |> assign(:fact_check_queue, [])
        |> assign(:evaluation, nil)
        |> assign(:page_title, "New Deliberation")
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("create_room", %{"topic" => topic}, socket) do
    # Create a new room under the DynamicSupervisor for fault tolerance
    {:ok, room_pid} = DynamicSupervisor.start_child(
      NervousSystem.RoomSupervisor,
      {Room, []}
    )
    room_state = Room.get_state(room_pid)
    room_id = room_state.id

    # Subscribe to updates
    Room.subscribe(room_id)

    # Start the deliberation
    Room.start_deliberation(room_pid, topic)

    socket =
      socket
      |> assign(:room_id, room_id)
      |> assign(:room, room_state)
      |> assign(:page_title, "Deliberation: #{topic}")
      |> push_patch(to: ~p"/room/#{room_id}")

    {:noreply, socket}
  end

  @impl true
  def handle_event("user_interject", %{"message" => message}, socket) when message != "" do
    if socket.assigns.room_id and not socket.assigns[:stopped] do
      Room.user_interject(Room.via_tuple(socket.assigns.room_id), message)
    end

    {:noreply, assign(socket, :user_input, "")}
  end

  @impl true
  def handle_event("user_interject", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_deliberation", _params, socket) do
    if socket.assigns.room_id do
      Room.stop_deliberation(Room.via_tuple(socket.assigns.room_id))
    end

    {:noreply, assign(socket, :stopped, true)}
  end

  @impl true
  def handle_event("update_topic", %{"topic" => topic}, socket) do
    {:noreply, assign(socket, :topic_input, topic)}
  end

  @impl true
  def handle_event("update_user_input", %{"message" => message}, socket) do
    {:noreply, assign(socket, :user_input, message)}
  end

  # PubSub message handlers

  @impl true
  def handle_info({:phase_changed, phase}, socket) do
    socket = update(socket, :room, fn room ->
      if room, do: %{room | phase: phase}, else: room
    end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:topic_set, topic}, socket) do
    socket = update(socket, :room, fn room ->
      if room, do: %{room | topic: topic}, else: room
    end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_speaking, personality, name}, socket) do
    socket =
      socket
      |> assign(:streaming_message, %{agent: name, personality: personality, content: ""})
      |> update(:room, fn room ->
        if room, do: %{room | current_speaker: personality}, else: room
      end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_chunk, _agent_name, chunk}, socket) do
    socket = update(socket, :streaming_message, fn
      nil -> nil
      msg -> %{msg | content: msg.content <> chunk}
    end)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_complete, agent_name, full_response}, socket) do
    personality = socket.assigns.streaming_message[:personality]

    # Skip adding Fact Checker messages to main chat - they appear as fact_check completions instead
    # Fact Checker uses non-streaming chat(), so don't touch streaming_message (another agent may be streaming)
    if agent_name == "The Fact Checker" do
      {:noreply, socket}
    else
      # Add completed message to list for other agents
      message = %{
        type: :agent,
        agent: agent_name,
        personality: personality,
        content: full_response,
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> update(:messages, &(&1 ++ [message]))
        |> assign(:streaming_message, nil)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:user_message, content}, socket) do
    message = %{
      type: :user,
      content: content,
      timestamp: DateTime.utc_now()
    }

    socket = update(socket, :messages, &(&1 ++ [message]))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_error, agent_name, reason}, socket) do
    message = %{
      type: :error,
      agent: agent_name,
      content: "Error: #{inspect(reason)}",
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:streaming_message, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:deliberation_stopped, reason}, socket) do
    message = %{
      type: :system,
      content: reason,
      timestamp: DateTime.utc_now()
    }

    socket =
      socket
      |> update(:messages, &(&1 ++ [message]))
      |> assign(:stopped, true)
      |> assign(:streaming_message, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:turn_limit_reached, turn_count}, socket) do
    message = %{
      type: :system,
      content: "Turn limit reached (#{turn_count} turns). Moving to synthesis...",
      timestamp: DateTime.utc_now()
    }

    socket = update(socket, :messages, &(&1 ++ [message]))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:turn_count_updated, turn_count}, socket) do
    {:noreply, assign(socket, :turn_count, turn_count)}
  end

  @impl true
  def handle_info({:evaluation_complete, evaluation}, socket) do
    {:noreply, assign(socket, :evaluation, evaluation)}
  end

  @impl true
  def handle_info({:fact_check_queued, queue_item}, socket) do
    require Logger
    Logger.debug("📥 LIVEVIEW: Received fact_check_queued for #{queue_item.id}")
    socket = update(socket, :fact_check_queue, &(&1 ++ [queue_item]))
    Logger.debug("📥 LIVEVIEW: Queue now has #{length(socket.assigns.fact_check_queue)} items")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:fact_check_complete, completed_item}, socket) do
    require Logger
    Logger.debug("📥 LIVEVIEW: Received fact_check_complete for #{completed_item.id} with status #{completed_item.status}")
    # Update the queue item status
    socket = update(socket, :fact_check_queue, fn queue ->
      Enum.map(queue, fn item ->
        if item.id == completed_item.id do
          completed_item
        else
          item
        end
      end)
    end)
    Logger.debug("📥 LIVEVIEW: Updated queue, statuses now: #{inspect(Enum.map(socket.assigns.fact_check_queue, & &1.status))}")

    # Also add a fact-check message to the main chat
    message = %{
      type: :fact_check,
      source_agent: completed_item.source_agent,
      claims: completed_item.claims,
      result: completed_item.result,
      verdict: completed_item.verdict,
      timestamp: DateTime.utc_now()
    }
    socket = update(socket, :messages, &(&1 ++ [message]))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:waiting_for_fact_checks, count}, socket) do
    message = %{
      type: :system,
      content: "⏳ Waiting for #{count} fact check(s) to complete before synthesis...",
      timestamp: DateTime.utc_now()
    }
    socket = update(socket, :messages, &(&1 ++ [message]))
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-900 text-gray-100">
      <div class="max-w-7xl mx-auto px-4 py-8">
        <!-- Header -->
        <header class="mb-8">
          <h1 class="text-3xl font-bold text-white mb-2">🧠 Nervous System</h1>
          <p class="text-gray-400">Multi-Agent Deliberation Engine</p>
        </header>

        <%= if @room_id do %>
          <!-- Active Room -->
          <div class="space-y-6">
            <!-- Topic, Phase, and Controls -->
            <div class="bg-gray-800 rounded-lg p-4">
              <div class="flex items-center justify-between">
                <div class="flex-1">
                  <span class="text-gray-400 text-sm">Topic:</span>
                  <h2 class="text-xl font-semibold text-white"><%= @room && @room.topic %></h2>
                </div>
                <div class="flex items-center gap-4">
                  <div class="text-center">
                    <span class="text-gray-400 text-sm">Turn</span>
                    <div class="text-lg font-mono text-white"><%= @turn_count %>/18</div>
                  </div>
                  <div class="text-center">
                    <span class="text-gray-400 text-sm">Phase</span>
                    <div class={"px-3 py-1 rounded-full text-sm font-medium #{phase_color(@room && @room.phase)}"}>
                      <%= format_phase(@room && @room.phase) %>
                    </div>
                  </div>
                  <%= unless @stopped do %>
                    <button
                      phx-click="stop_deliberation"
                      class="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded-lg font-medium transition-colors flex items-center gap-2"
                    >
                      <span>⏹</span> Stop
                    </button>
                  <% end %>
                </div>
              </div>
            </div>

            <!-- Agent Status Bar -->
            <div class="flex justify-center gap-4 flex-wrap">
              <.agent_badge
                :for={agent <- (@room && @room.agents) || []}
                personality={agent.personality}
                active={@room && @room.current_speaker == agent.personality}
              />
            </div>

            <!-- Two-column layout: Main thread + Fact Check Sidebar -->
            <div class="flex gap-6 items-start overflow-hidden">
              <!-- Main Thread (left column) -->
              <div class="flex-1 min-w-0 space-y-4">
                <!-- Messages -->
                <div class="bg-gray-800 rounded-lg p-4 min-h-[500px] max-h-[700px] overflow-y-auto" id="messages" phx-hook="ScrollToBottom">
                  <div class="space-y-4">
                    <%= for message <- @messages do %>
                      <.message_bubble message={message} />
                    <% end %>

                    <!-- Streaming message -->
                    <%= if @streaming_message do %>
                      <.message_bubble message={%{
                        type: :agent,
                        agent: @streaming_message.agent,
                        personality: @streaming_message.personality,
                        content: @streaming_message.content,
                        streaming: true
                      }} />
                    <% end %>
                  </div>
                </div>

                <!-- User Input -->
                <%= if @stopped do %>
                  <div class="bg-gray-800 rounded-lg p-4 text-center">
                    <span class="text-gray-400">Discussion has ended</span>
                  </div>

                  <!-- Quality Report -->
                  <%= if @evaluation do %>
                    <%= if @evaluation.status == :error do %>
                      <div class="bg-red-900/30 border border-red-500/30 rounded-lg p-4 mt-4">
                        <div class="flex items-center gap-2 text-red-400">
                          <span>⚠️</span>
                          <span class="font-medium">Evaluation Failed</span>
                        </div>
                        <p class="text-gray-400 text-sm mt-2">
                          <%= @evaluation.details[:error] || "Unable to evaluate discussion quality" %>
                        </p>
                      </div>
                    <% else %>
                      <.quality_report evaluation={@evaluation} />
                    <% end %>
                  <% else %>
                    <div class="bg-gray-800 rounded-lg p-4 mt-4">
                      <div class="flex items-center gap-2 text-gray-400">
                        <span class="animate-pulse">📊</span>
                        <span>Evaluating discussion quality...</span>
                      </div>
                    </div>
                  <% end %>
                <% else %>
                  <form phx-submit="user_interject" class="flex gap-2">
                    <input
                      type="text"
                      name="message"
                      value={@user_input}
                      phx-change="update_user_input"
                      placeholder="Interject a question or comment..."
                      class="flex-1 bg-gray-700 border border-gray-600 rounded-lg px-4 py-2 text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                    />
                    <button
                      type="submit"
                      class="bg-blue-600 hover:bg-blue-700 text-white px-6 py-2 rounded-lg font-medium transition-colors"
                    >
                      Send
                    </button>
                  </form>
                <% end %>
              </div>

              <!-- Fact Check Sidebar (right column) -->
              <div class="w-80 flex-shrink-0">
                <div class="bg-teal-900/30 border border-teal-500/30 rounded-lg p-4 sticky top-4">
                  <div class="flex items-center gap-2 mb-3">
                    <span class="text-teal-400 font-medium">🔍 Fact Checker</span>
                    <%= if length(@fact_check_queue) > 0 do %>
                      <span class="bg-teal-500/20 text-teal-300 text-xs px-2 py-0.5 rounded-full">
                        <%= length(Enum.filter(@fact_check_queue, &(&1.status == :checking))) %> active
                      </span>
                    <% end %>
                  </div>

                  <!-- Verdict Summary -->
                  <%= if Enum.any?(@fact_check_queue, &(&1.status == :complete)) do %>
                    <div class="flex gap-2 mb-3 flex-wrap">
                      <% verdicts = Enum.frequencies_by(@fact_check_queue, & &1.verdict) %>
                      <%= if Map.get(verdicts, :verified, 0) > 0 do %>
                        <span class="bg-green-500/20 text-green-400 text-xs px-2 py-1 rounded">
                          ✓ <%= Map.get(verdicts, :verified) %> verified
                        </span>
                      <% end %>
                      <%= if Map.get(verdicts, :partial, 0) > 0 do %>
                        <span class="bg-yellow-500/20 text-yellow-400 text-xs px-2 py-1 rounded">
                          ⚠ <%= Map.get(verdicts, :partial) %> partial
                        </span>
                      <% end %>
                      <%= if Map.get(verdicts, :disputed, 0) + Map.get(verdicts, :false, 0) > 0 do %>
                        <span class="bg-red-500/20 text-red-400 text-xs px-2 py-1 rounded">
                          ✗ <%= Map.get(verdicts, :disputed, 0) + Map.get(verdicts, :false, 0) %> disputed
                        </span>
                      <% end %>
                      <%= if Map.get(verdicts, :unverifiable, 0) + Map.get(verdicts, :unknown, 0) > 0 do %>
                        <span class="bg-gray-500/20 text-gray-400 text-xs px-2 py-1 rounded">
                          ? <%= Map.get(verdicts, :unverifiable, 0) + Map.get(verdicts, :unknown, 0) %> unknown
                        </span>
                      <% end %>
                    </div>
                  <% end %>

                  <%= if length(@fact_check_queue) > 0 do %>
                    <div class="space-y-2 max-h-[500px] overflow-y-auto">
                      <%= for item <- Enum.reverse(@fact_check_queue) do %>
                        <div class={"p-3 rounded-lg #{verdict_bg(item.verdict, item.status)}"}>
                          <div class="flex items-center justify-between mb-1">
                            <div class="flex items-center gap-2">
                              <span class="text-base"><%= verdict_icon(item.verdict, item.status) %></span>
                              <span class={"text-xs px-2 py-0.5 rounded font-medium #{verdict_badge(item.verdict, item.status)}"}>
                                <%= verdict_label(item.verdict, item.status) %>
                              </span>
                            </div>
                          </div>
                          <div class="text-xs text-gray-400 mb-1">
                            <span class="text-gray-300"><%= item.source_agent %></span>
                          </div>
                          <div class="text-xs text-gray-300 line-clamp-2">
                            <%= Enum.at(item.claims, 0) |> String.slice(0..100) %><%= if String.length(Enum.at(item.claims, 0) || "") > 100, do: "..." %>
                          </div>
                          <%= if item.status == :complete && item.result do %>
                            <details class="mt-2">
                              <summary class="text-xs text-teal-400 cursor-pointer hover:text-teal-300">View details</summary>
                              <div class="mt-1 text-xs text-gray-400 max-h-40 overflow-y-auto whitespace-pre-wrap break-words">
                                <%= String.slice(item.result, 0..600) %><%= if String.length(item.result || "") > 600, do: "..." %>
                              </div>
                            </details>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="text-sm text-gray-500 text-center py-4">
                      No fact checks queued yet.<br/>
                      Claims will be detected automatically.
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% else %>
          <!-- New Room Form -->
          <div class="max-w-xl mx-auto">
            <div class="bg-gray-800 rounded-lg p-8">
              <h2 class="text-2xl font-bold text-white mb-6">Start a New Deliberation</h2>
              <form phx-submit="create_room" class="space-y-4">
                <div>
                  <label class="block text-gray-300 mb-2">Topic for Discussion</label>
                  <textarea
                    name="topic"
                    rows="3"
                    phx-change="update_topic"
                    placeholder="e.g., Will AI replace programmers within the next decade?"
                    class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-3 text-white placeholder-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  ><%= @topic_input %></textarea>
                </div>

                <div class="bg-gray-700/50 rounded-lg p-4">
                  <h3 class="text-sm font-medium text-gray-300 mb-3">9 AI Agents</h3>
                  <div class="grid grid-cols-3 gap-2 text-xs">
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-blue-500"></span>
                      <span class="text-gray-300">Analyst <span class="text-gray-500">(Sonnet)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-green-500"></span>
                      <span class="text-gray-300">Advocate <span class="text-gray-500">(GPT-4)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-red-500"></span>
                      <span class="text-gray-300">Skeptic <span class="text-gray-500">(Gemini)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-amber-500"></span>
                      <span class="text-gray-300">Historian <span class="text-gray-500">(Sonnet)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-cyan-500"></span>
                      <span class="text-gray-300">Futurist <span class="text-gray-500">(GPT-4)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-orange-500"></span>
                      <span class="text-gray-300">Pragmatist <span class="text-gray-500">(Gemini)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-pink-500"></span>
                      <span class="text-gray-300">Ethicist <span class="text-yellow-400 font-medium">(Opus)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-purple-500"></span>
                      <span class="text-gray-300">Synthesizer <span class="text-yellow-400 font-medium">(Opus)</span></span>
                    </div>
                    <div class="flex items-center gap-2">
                      <span class="w-2 h-2 rounded-full bg-teal-500"></span>
                      <span class="text-gray-300">Fact Checker <span class="text-gray-500">(Perplexity)</span></span>
                    </div>
                  </div>
                </div>

                <button
                  type="submit"
                  disabled={@topic_input == ""}
                  class="w-full bg-blue-600 hover:bg-blue-700 disabled:bg-gray-600 disabled:cursor-not-allowed text-white px-6 py-3 rounded-lg font-medium transition-colors"
                >
                  Begin Deliberation
                </button>
              </form>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Components

  attr :personality, :atom, required: true
  attr :active, :boolean, default: false

  defp agent_badge(assigns) do
    ~H"""
    <div class={"flex items-center gap-2 px-3 py-1 rounded-full text-sm #{if @active, do: "bg-blue-500/20 ring-2 ring-blue-500", else: "bg-gray-700"}"}>
      <span class={"w-2 h-2 rounded-full #{personality_color(@personality)} #{if @active, do: "animate-pulse"}"}>
      </span>
      <span class={if @active, do: "text-blue-300 font-medium", else: "text-gray-400"}>
        <%= format_personality(@personality) %>
      </span>
    </div>
    """
  end

  attr :message, :map, required: true

  defp message_bubble(assigns) do
    ~H"""
    <div class={"p-4 rounded-lg #{message_bg(@message)}"}>
      <%= case @message.type do %>
        <% :user -> %>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-yellow-400 text-sm font-medium">👤 You</span>
          </div>
        <% :system -> %>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-purple-400 text-sm font-medium">⚙️ System</span>
          </div>
        <% :error -> %>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-red-400 text-sm font-medium">⚠️ <%= @message.agent %></span>
          </div>
        <% :fact_check -> %>
          <div class="flex items-center gap-2 mb-2">
            <span class="w-2 h-2 rounded-full bg-teal-500"></span>
            <span class="text-teal-400 text-sm font-medium">🔍 Fact Check</span>
            <span class="text-gray-500 text-xs">re: <%= @message.source_agent %></span>
            <span class={"text-xs px-2 py-0.5 rounded font-bold #{verdict_text_color(@message[:verdict])}"}>
              <%= verdict_emoji(@message[:verdict]) %> <%= verdict_label(@message[:verdict], :complete) %>
            </span>
          </div>
        <% _ -> %>
          <div class="flex items-center gap-2 mb-2">
            <span class={"w-2 h-2 rounded-full #{personality_color(@message[:personality])}"}>
            </span>
            <span class="text-sm font-medium text-gray-300"><%= @message.agent %></span>
            <%= if @message[:streaming] do %>
              <span class="text-xs text-blue-400 animate-pulse">typing...</span>
            <% end %>
          </div>
      <% end %>
      <%= if @message.type == :fact_check do %>
        <div class="text-gray-200 whitespace-pre-wrap break-words overflow-hidden"><%= @message.result %></div>
      <% else %>
        <div class="text-gray-200 whitespace-pre-wrap break-words overflow-hidden"><%= @message.content %><%= if @message[:streaming], do: "▊" %></div>
      <% end %>
    </div>
    """
  end

  # Helpers

  defp phase_color(:framework), do: "bg-yellow-500/20 text-yellow-300"
  defp phase_color(:discussion), do: "bg-blue-500/20 text-blue-300"
  defp phase_color(:synthesis), do: "bg-green-500/20 text-green-300"
  defp phase_color(:stopped), do: "bg-red-500/20 text-red-300"
  defp phase_color(_), do: "bg-gray-500/20 text-gray-300"

  defp format_phase(:framework), do: "Framework"
  defp format_phase(:discussion), do: "Discussion"
  defp format_phase(:synthesis), do: "Synthesis"
  defp format_phase(:stopped), do: "Stopped"
  defp format_phase(_), do: "Starting..."

  defp personality_color(:analyst), do: "bg-blue-500"
  defp personality_color(:advocate), do: "bg-green-500"
  defp personality_color(:skeptic), do: "bg-red-500"
  defp personality_color(:historian), do: "bg-amber-500"
  defp personality_color(:futurist), do: "bg-cyan-500"
  defp personality_color(:pragmatist), do: "bg-orange-500"
  defp personality_color(:ethicist), do: "bg-pink-500"
  defp personality_color(:synthesizer), do: "bg-purple-500"
  defp personality_color(:fact_checker), do: "bg-teal-500"
  defp personality_color(_), do: "bg-gray-500"

  defp format_personality(:analyst), do: "Analyst"
  defp format_personality(:advocate), do: "Advocate"
  defp format_personality(:skeptic), do: "Skeptic"
  defp format_personality(:historian), do: "Historian"
  defp format_personality(:futurist), do: "Futurist"
  defp format_personality(:pragmatist), do: "Pragmatist"
  defp format_personality(:ethicist), do: "Ethicist"
  defp format_personality(:synthesizer), do: "Synthesizer"
  defp format_personality(:fact_checker), do: "Fact Checker"
  defp format_personality(_), do: "Unknown"

  defp message_bg(%{type: :user}), do: "bg-yellow-500/10 border border-yellow-500/20"
  defp message_bg(%{type: :error}), do: "bg-red-500/10 border border-red-500/20"
  defp message_bg(%{type: :system}), do: "bg-purple-500/10 border border-purple-500/20"
  defp message_bg(%{type: :fact_check, verdict: :verified}), do: "bg-green-500/10 border-l-4 border-l-green-500 border border-green-500/20"
  defp message_bg(%{type: :fact_check, verdict: :partial}), do: "bg-yellow-500/10 border-l-4 border-l-yellow-500 border border-yellow-500/20"
  defp message_bg(%{type: :fact_check, verdict: :disputed}), do: "bg-red-500/10 border-l-4 border-l-red-500 border border-red-500/20"
  defp message_bg(%{type: :fact_check, verdict: :false}), do: "bg-red-500/15 border-l-4 border-l-red-600 border border-red-500/30"
  defp message_bg(%{type: :fact_check}), do: "bg-teal-500/10 border-l-4 border-l-teal-500 border border-teal-500/20"
  defp message_bg(_), do: "bg-gray-700/50"

  defp verdict_text_color(:verified), do: "bg-green-500/20 text-green-400"
  defp verdict_text_color(:partial), do: "bg-yellow-500/20 text-yellow-400"
  defp verdict_text_color(:disputed), do: "bg-red-500/20 text-red-400"
  defp verdict_text_color(:false), do: "bg-red-500/30 text-red-400"
  defp verdict_text_color(:unverifiable), do: "bg-gray-500/20 text-gray-400"
  defp verdict_text_color(_), do: "bg-gray-500/20 text-gray-400"

  defp verdict_emoji(:verified), do: "✓"
  defp verdict_emoji(:partial), do: "⚠"
  defp verdict_emoji(:disputed), do: "✗"
  defp verdict_emoji(:false), do: "✗"
  defp verdict_emoji(:unverifiable), do: "?"
  defp verdict_emoji(_), do: "?"

  # Verdict-based styling (used when status is complete)
  defp verdict_bg(:verified, :complete), do: "bg-green-500/10 border border-green-500/30"
  defp verdict_bg(:partial, :complete), do: "bg-yellow-500/10 border border-yellow-500/30"
  defp verdict_bg(:disputed, :complete), do: "bg-red-500/10 border border-red-500/30"
  defp verdict_bg(:false, :complete), do: "bg-red-500/15 border border-red-500/40"
  defp verdict_bg(:unverifiable, :complete), do: "bg-gray-500/10 border border-gray-500/30"
  defp verdict_bg(:unknown, :complete), do: "bg-blue-500/10 border border-blue-500/30"
  defp verdict_bg(_, :complete), do: "bg-teal-500/10 border border-teal-500/30"
  defp verdict_bg(_, :checking), do: "bg-yellow-500/10 border border-yellow-500/20 animate-pulse"
  defp verdict_bg(_, _), do: "bg-gray-500/10 border border-gray-500/20"

  defp verdict_icon(:verified, :complete), do: "✓"
  defp verdict_icon(:partial, :complete), do: "⚠"
  defp verdict_icon(:disputed, :complete), do: "✗"
  defp verdict_icon(:false, :complete), do: "✗"
  defp verdict_icon(:unverifiable, :complete), do: "?"
  defp verdict_icon(:unknown, :complete), do: "●"
  defp verdict_icon(_, :complete), do: "✓"
  defp verdict_icon(_, :checking), do: "⏳"
  defp verdict_icon(_, _), do: "○"

  defp verdict_badge(:verified, :complete), do: "bg-green-500/20 text-green-400"
  defp verdict_badge(:partial, :complete), do: "bg-yellow-500/20 text-yellow-400"
  defp verdict_badge(:disputed, :complete), do: "bg-red-500/20 text-red-400"
  defp verdict_badge(:false, :complete), do: "bg-red-500/30 text-red-400"
  defp verdict_badge(:unverifiable, :complete), do: "bg-gray-500/20 text-gray-400"
  defp verdict_badge(:unknown, :complete), do: "bg-blue-500/20 text-blue-400"
  defp verdict_badge(_, :complete), do: "bg-teal-500/20 text-teal-400"
  defp verdict_badge(_, :checking), do: "bg-yellow-500/20 text-yellow-300"
  defp verdict_badge(_, _), do: "bg-gray-500/20 text-gray-400"

  defp verdict_label(:verified, :complete), do: "VERIFIED"
  defp verdict_label(:partial, :complete), do: "PARTIAL"
  defp verdict_label(:disputed, :complete), do: "DISPUTED"
  defp verdict_label(:false, :complete), do: "FALSE"
  defp verdict_label(:unverifiable, :complete), do: "UNVERIFIABLE"
  defp verdict_label(:unknown, :complete), do: "REVIEWED"
  defp verdict_label(_, :complete), do: "COMPLETE"
  defp verdict_label(_, :checking), do: "CHECKING..."
  defp verdict_label(_, _), do: "PENDING"

  # Quality Report Component
  defp quality_report(assigns) do
    ~H"""
    <div class="bg-gray-800 rounded-lg p-4 mt-4">
      <details class="group">
        <summary class="flex items-center justify-between cursor-pointer list-none">
          <div class="flex items-center gap-3">
            <span class="text-lg">📊</span>
            <span class="font-medium text-white">Quality Report</span>
            <span class={"px-2 py-0.5 rounded text-sm font-medium #{score_color(@evaluation.overall)}"}>
              <%= @evaluation.overall %>/100
            </span>
          </div>
          <span class="text-gray-400 group-open:rotate-180 transition-transform">▼</span>
        </summary>

        <div class="mt-4 space-y-3">
          <%= for {dimension, score} <- score_pairs(@evaluation.scores) do %>
            <div class="space-y-1">
              <div class="flex justify-between text-sm">
                <span class="text-gray-300"><%= format_dimension(dimension) %></span>
                <span class={"font-medium #{dimension_score_color(score)}"}><%= score %>/10</span>
              </div>
              <div class="h-2 bg-gray-700 rounded-full overflow-hidden">
                <div
                  class={"h-full rounded-full #{progress_bar_color(score)}"}
                  style={"width: #{score * 10}%"}
                />
              </div>
              <%= if Map.has_key?(@evaluation.details, dimension) do %>
                <p class="text-xs text-gray-400 mt-1">
                  <%= Map.get(@evaluation.details, dimension) %>
                </p>
              <% end %>
            </div>
          <% end %>
        </div>
      </details>
    </div>
    """
  end

  defp score_pairs(scores) do
    [
      {:engagement, scores.engagement},
      {:evidence, scores.evidence},
      {:diversity, scores.diversity},
      {:context_integration, scores.context_integration},
      {:actionability, scores.actionability},
      {:synthesis, scores.synthesis},
      {:fact_checking, scores.fact_checking},
      {:conciseness, scores.conciseness}
    ]
  end

  defp format_dimension(:engagement), do: "Engagement"
  defp format_dimension(:evidence), do: "Evidence"
  defp format_dimension(:diversity), do: "Diversity"
  defp format_dimension(:context_integration), do: "Context Integration"
  defp format_dimension(:actionability), do: "Actionability"
  defp format_dimension(:synthesis), do: "Synthesis"
  defp format_dimension(:fact_checking), do: "Fact Checking"
  defp format_dimension(:conciseness), do: "Conciseness"
  defp format_dimension(other), do: to_string(other) |> String.capitalize()

  defp score_color(score) when score >= 80, do: "bg-green-500/20 text-green-400"
  defp score_color(score) when score >= 60, do: "bg-yellow-500/20 text-yellow-400"
  defp score_color(_), do: "bg-red-500/20 text-red-400"

  defp dimension_score_color(score) when score >= 8, do: "text-green-400"
  defp dimension_score_color(score) when score >= 6, do: "text-yellow-400"
  defp dimension_score_color(_), do: "text-red-400"

  defp progress_bar_color(score) when score >= 8, do: "bg-green-500"
  defp progress_bar_color(score) when score >= 6, do: "bg-yellow-500"
  defp progress_bar_color(_), do: "bg-red-500"
end
