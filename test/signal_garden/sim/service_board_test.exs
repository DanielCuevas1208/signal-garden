defmodule SignalGarden.Sim.ServiceBoardTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario}

  @expected %{
    "api" => %{value: "operational", version: 1},
    "cache" => %{value: "down", version: 4},
    "db" => %{value: "operational", version: 5},
    "queue" => %{value: "operational", version: 3}
  }

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "an lww map scenario converges to the latest write of every key" do
    state = run_to_completion(:service_board)

    assert state.status == :converged
    assert state.writes_issued == 5
    assert state.map_fields == @expected

    fields =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).fields
      end)

    assert Enum.all?(fields, &(&1 == @expected))
  end

  test "two map runs converge at the same logical clock" do
    a = run_to_completion(:service_board)
    b = run_to_completion(:service_board)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
    assert a.map_fields == b.map_fields
  end

  test "the run does not converge before all scheduled writes are issued" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    {state, _} = Core.step(state, 500)

    refute state.status == :converged
    assert MapSet.size(state.informed) == 0
  end

  # ---------------------------------------------------------------------------
  # put commands
  # ---------------------------------------------------------------------------

  test "a manual put writes one key on the writing node" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    state = Core.command(state, {:put, 3, "api", "degraded"})

    assert state.writes_issued == 1
    assert state.map_fields["api"] == %{value: "degraded", version: 1}

    fields = get_in(state.nodes, [3, :known, state.origin]).fields
    assert fields["api"] == %{value: "degraded", version: 1}
    refute Map.has_key?(fields, "db")
  end

  test "put commands are ignored outside map mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:put, 2, "api", "down"})

    assert state.writes_issued == 0
    assert state.map_fields == %{}
  end

  test "a manual put after convergence re-arms the run" do
    state = run_to_completion(:service_board)
    assert state.status == :converged

    state = Core.command(state, {:put, 2, "api", "maintenance"})
    assert state.status == :idle
    assert state.writes_issued == 6
    assert state.map_fields["api"].value == "maintenance"

    state = run_to_converge(state)
    assert state.status == :converged
    assert state.map_fields["api"].value == "maintenance"

    fields =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).fields
      end)

    assert Enum.all?(fields, &(&1["api"].value == "maintenance"))
  end

  test "a scheduled put does not move the convergence target" do
    scenario = %Scenario{
      Scenarios.service_board()
      | fault_schedule: [%{at: 10, action: {:put, 2, "api", "down"}, label: "put"}]
    }

    state = Core.new(scenario)
    state = step_n(state, 20)

    assert state.writes_issued == 1
    assert state.writes_target == 1
    assert state.map_fields["api"].value == "down"
  end

  # ---------------------------------------------------------------------------
  # last-writer-wins merge semantics
  # ---------------------------------------------------------------------------

  test "delivering a message keeps the higher version for each key" do
    state = Scenarios.fetch(:service_board) |> Core.new()

    # Node 1 writes api at version 1, node 2 writes api at version 2.
    state = state |> Core.command({:put, 1, "api", "degraded"})
    state = Core.command(state, {:put, 2, "api", "operational"})

    # An older payload never overwrites a newer value for that key.
    old_payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, old_payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    fields = get_in(state.nodes, [2, :known, state.origin]).fields
    assert fields["api"] == %{value: "operational", version: 2}

    # A newer payload flows into a node that only holds an old value.
    state = state |> Core.command({:put, 3, "api", "down"})
    fresh_payload = get_in(state.nodes, [3, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 1, fresh_payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    fields = get_in(state.nodes, [1, :known, state.origin]).fields
    assert fields["api"] == %{value: "down", version: 3}
  end

  test "merging a message keeps keys the receiver holds but the sender does not" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    state = state |> Core.command({:put, 1, "api", "operational"})
    state = Core.command(state, {:put, 2, "db", "degraded"})

    # Node 1 knows only "api"; hand its map to node 2.
    payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    fields = get_in(state.nodes, [2, :known, state.origin]).fields
    assert fields["api"].value == "operational"
    assert fields["db"].value == "degraded"
  end

  test "a put of the same value still moves that key forward" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    state = state |> Core.command({:put, 1, "api", "operational"})
    state = Core.command(state, {:put, 2, "api", "operational"})

    assert state.writes_issued == 2
    assert state.map_fields["api"] == %{value: "operational", version: 2}

    fields = get_in(state.nodes, [2, :known, state.origin]).fields
    assert fields["api"].version == 2
  end

  # ---------------------------------------------------------------------------
  # faults and map state
  # ---------------------------------------------------------------------------

  test "crashing a map node drops its fields" do
    state = Scenarios.fetch(:service_board) |> Core.new()

    state = %{state | queue: []}
    state = Core.command(state, {:put, 7, "api", "down"})
    assert get_in(state.nodes, [7, :known, state.origin]).fields["api"].value == "down"

    state = Core.command(state, {:crash, 7})
    assert get_in(state.nodes, [7, :known, state.origin]).fields == %{}
    refute state.nodes[7].up
  end

  test "a permanently crashed map node blocks convergence" do
    scenario = %Scenario{
      Scenarios.service_board()
      | topology: SignalGarden.Sim.Topology.line(6),
        seed: 5,
        origin: 1,
        fault_schedule: [%{at: 100, action: {:put, 1, "api", "operational"}, label: "put"}]
    }

    state = Core.new(scenario)
    state = Core.command(state, {:crash, 6})
    state = run_to_converge(state)

    refute state.status == :converged
    assert state.nodes[6].up == false
  end

  test "restarting a map node lets it re-learn the full map" do
    state = run_to_completion(:service_board)
    state = Core.command(state, {:crash, 5})
    state = Core.command(state, {:restart, 5})

    assert get_in(state.nodes, [5, :known, state.origin]).fields == %{}

    state = run_to_converge(state)
    fields = get_in(state.nodes, [5, :known, state.origin]).fields
    assert fields == @expected
  end

  test "put faults appear in the event log" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    state = Core.command(state, {:put, 3, "api", "degraded"})

    assert :put in Enum.map(state.event_log, & &1.kind)
    assert Enum.any?(state.event_log, &(&1.kind == :put and &1.key == "api"))
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "the snapshot exposes map fields" do
    state = Scenarios.fetch(:service_board) |> Core.new()
    state = state |> Core.command({:put, 1, "api", "operational"})
    snap = Core.snapshot(state)

    assert snap.mode == :map
    assert snap.map_writes == 1
    assert snap.map_keys == ["api", "cache", "db", "queue"]
    assert snap.map_fields == [%{key: "api", value: "operational", version: 1}]

    node = Enum.find(snap.nodes, &(&1.id == 1))
    assert node.value == 1
    assert node.version == 1

    fresh = Enum.find(snap.nodes, &(&1.id == 2))
    assert fresh.value == 0
    assert fresh.version == 0
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp run_to_completion(id) do
    Scenarios.fetch(id) |> Core.new() |> run_to_converge()
  end

  defp run_to_converge(%Core{} = state), do: await(state, :converged, 200_000)

  defp step_n(%Core{} = state, events) do
    {state, _} = Core.step(state, events)
    state
  end

  defp await(%Core{} = state, target, budget) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..div(budget, 50)//1, state, fn _, acc ->
      acc = step_n(acc, 50)
      if acc.status == target, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
