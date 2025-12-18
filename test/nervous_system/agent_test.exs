defmodule NervousSystem.AgentTest do
  use ExUnit.Case, async: true

  alias NervousSystem.Agent

  describe "start_link/1" do
    test "creates an agent with required personality" do
      {:ok, pid} = Agent.start_link(personality: :analyst)
      state = Agent.get_state(pid)

      assert state.personality == :analyst
      assert state.name == "The Analyst"
      assert state.status == :idle
      assert state.memory == []
    end

    test "creates agents for all personalities" do
      personalities = [:analyst, :advocate, :skeptic, :historian, :futurist, :pragmatist, :ethicist, :synthesizer, :fact_checker]

      for personality <- personalities do
        {:ok, pid} = Agent.start_link(personality: personality)
        state = Agent.get_state(pid)

        assert state.personality == personality
        assert is_binary(state.name)
      end
    end

    test "fails for unknown personality" do
      # GenServer raises in init, which returns {:error, _}
      # We trap exits to prevent the test from crashing
      Process.flag(:trap_exit, true)

      result = Agent.start_link(personality: :unknown_personality)

      # May return error tuple or cause a trapped exit
      case result do
        {:error, _} -> :ok
        {:ok, _pid} -> flunk("Expected error for unknown personality")
      end
    catch
      :exit, _ -> :ok
    end

    test "accepts provider option" do
      {:ok, pid} = Agent.start_link(personality: :analyst, provider: :openai)
      state = Agent.get_state(pid)

      assert state.provider == :openai
    end

    test "defaults to anthropic provider" do
      {:ok, pid} = Agent.start_link(personality: :analyst)
      state = Agent.get_state(pid)

      assert state.provider == :anthropic
    end

    test "accepts model option" do
      {:ok, pid} = Agent.start_link(personality: :analyst, model: "custom-model")
      state = Agent.get_state(pid)

      assert state.model == "custom-model"
    end

    test "accepts room_pid option" do
      {:ok, pid} = Agent.start_link(personality: :analyst, room_pid: self())
      state = Agent.get_state(pid)

      assert state.room_pid == self()
    end
  end

  describe "add_to_memory/2" do
    test "adds messages to agent memory" do
      {:ok, pid} = Agent.start_link(personality: :analyst)

      Agent.add_to_memory(pid, %{role: "user", content: "Hello"})
      Agent.add_to_memory(pid, %{role: "assistant", content: "Hi there"})

      # Give time for async cast to process
      :timer.sleep(10)

      state = Agent.get_state(pid)
      assert length(state.memory) == 2
      assert Enum.at(state.memory, 0).content == "Hello"
      assert Enum.at(state.memory, 1).content == "Hi there"
    end
  end

  describe "clear_memory/1" do
    test "clears agent memory" do
      {:ok, pid} = Agent.start_link(personality: :analyst)

      Agent.add_to_memory(pid, %{role: "user", content: "Hello"})
      :timer.sleep(10)

      Agent.clear_memory(pid)
      :timer.sleep(10)

      state = Agent.get_state(pid)
      assert state.memory == []
    end
  end

  describe "personalities/0" do
    test "returns all available personalities" do
      personalities = Agent.personalities()

      assert :analyst in personalities
      assert :advocate in personalities
      assert :skeptic in personalities
      assert :historian in personalities
      assert :futurist in personalities
      assert :pragmatist in personalities
      assert :ethicist in personalities
      assert :synthesizer in personalities
      assert :fact_checker in personalities
      assert length(personalities) == 9
    end
  end

  describe "get_personality/1" do
    test "returns personality config for valid personality" do
      config = Agent.get_personality(:analyst)

      assert config.name == "The Analyst"
      assert is_binary(config.system_prompt)
      assert String.contains?(config.system_prompt, "evidence")
    end

    test "returns nil for invalid personality" do
      assert Agent.get_personality(:invalid) == nil
    end
  end
end
