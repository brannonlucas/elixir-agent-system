defmodule NervousSystem.RoomTest do
  use ExUnit.Case, async: true

  alias NervousSystem.Room

  describe "start_link/1" do
    test "creates a room with a unique ID" do
      {:ok, pid1} = Room.start_link([])
      {:ok, pid2} = Room.start_link([])

      state1 = Room.get_state(pid1)
      state2 = Room.get_state(pid2)

      assert state1.id != state2.id
      assert is_binary(state1.id)
      assert is_binary(state2.id)
    end

    test "creates a room with provided ID" do
      {:ok, pid} = Room.start_link(id: "test-room-123")
      state = Room.get_state(pid)

      assert state.id == "test-room-123"
    end

    test "initializes with nil phase before deliberation starts" do
      {:ok, pid} = Room.start_link([])
      state = Room.get_state(pid)

      assert state.phase == nil
      assert state.topic == nil
      assert state.messages == []
    end

    test "creates 9 agents with expected personalities" do
      {:ok, pid} = Room.start_link([])
      state = Room.get_state(pid)

      expected_personalities = [:analyst, :advocate, :skeptic, :historian, :futurist, :pragmatist, :ethicist, :synthesizer, :fact_checker]
      actual_personalities = Enum.map(state.agents, fn %{personality: p} -> p end) |> Enum.sort()

      assert Enum.sort(expected_personalities) == actual_personalities
    end
  end

  describe "start_deliberation/2" do
    test "sets topic and starts framework phase" do
      {:ok, pid} = Room.start_link([])

      :ok = Room.start_deliberation(pid, "Test topic")
      state = Room.get_state(pid)

      assert state.topic == "Test topic"
      assert state.phase == :framework
      assert state.turn_count == 1
      assert state.current_speaker == :analyst
    end
  end

  describe "stop_deliberation/1" do
    test "stops the deliberation" do
      {:ok, pid} = Room.start_link([])
      :ok = Room.start_deliberation(pid, "Test topic")

      :ok = Room.stop_deliberation(pid)
      state = Room.get_state(pid)

      assert state.stopped == true
      assert state.phase == :stopped
    end
  end

  describe "via_tuple/1" do
    test "returns registry tuple for room lookup" do
      tuple = Room.via_tuple("test-id")

      assert {:via, Registry, {NervousSystem.RoomRegistry, "test-id"}} = tuple
    end
  end
end
