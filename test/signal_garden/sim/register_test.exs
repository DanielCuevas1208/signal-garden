defmodule SignalGarden.Sim.RegisterTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario}

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "an lww register scenario converges to the last scheduled write" do
    state = run_to_completion(:bulletin)

    assert state.status == :converged
    assert state.writes_issued == 5
    assert state.register_value == "All systems nominal"

    values =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin])
      end)

    assert Enum.all?(values, &(&1.value == "All systems nominal"))
    assert Enum.all?(values, &(&1.version == 5))
  end

  test "two register runs converge at the same logical clock" do
    a = run_to_completion(:bulletin)
    b = run_to_completion(:bulletin)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
    assert a.register_value == b.register_value
  end

  test "the run does not converge before all scheduled writes are issued" do
    state = Scenarios.fetch(:bulletin) |> Core.new()
    {state, _} = Core.step(state, 500)

    refute state.status == :converged
    assert MapSet.size(state.informed) == 0
  end

  # ---------------------------------------------------------------------------
  # write commands
  # ---------------------------------------------------------------------------

  test "a manual write puts a new value on the writing node" do
    state = Scenarios.fetch(:bulletin) |> Core.new()
    state = Core.command(state, {:write, 3, "Backup complete"})

    assert state.writes_issued == 1
    assert state.register_value == "Backup complete"

    known = get_in(state.nodes, [3, :known, state.origin])
    assert known.value == "Backup complete"
    assert known.version == 1
  end

  test "write commands are ignored outside register mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:write, 2, "ignored"})

    assert state.writes_issued == 0
    assert state.register_value == nil
  end

  test "a manual write after convergence re-arms the run" do
    state = run_to_completion(:bulletin)
    assert state.status == :converged

    state = Core.command(state, {:write, 2, "Manual notice"})
    assert state.status == :idle
    assert state.writes_issued == 6
    assert state.register_value == "Manual notice"

    state = run_to_converge(state)
    assert state.status == :converged
    assert state.register_value == "Manual notice"

    values =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).value
      end)

    assert Enum.all?(values, &(&1 == "Manual notice"))
  end

  test "a scheduled write does not move the convergence target" do
    scenario = %Scenario{
      Scenarios.bulletin()
      | fault_schedule: [%{at: 10, action: {:write, 2, "One notice"}, label: "write"}]
    }

    state = Core.new(scenario)
    state = step_n(state, 20)

    assert state.writes_issued == 1
    assert state.writes_target == 1
    assert state.register_value == "One notice"
  end

  # ---------------------------------------------------------------------------
  # last-writer-wins semantics
  # ---------------------------------------------------------------------------

  test "delivering a message keeps the value with the higher version" do
    state = Scenarios.fetch(:bulletin) |> Core.new()

    state =
      state |> Core.command({:write, 1, "Old notice"}) |> Core.command({:write, 2, "New notice"})

    assert state.writes_issued == 2
    assert state.register_value == "New notice"

    # An older payload never overwrites a newer value in place.
    old_payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, old_payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    known = get_in(state.nodes, [2, :known, state.origin])
    assert known.value == "New notice"
    assert known.version == 2

    # A newer payload flows into a node that only holds the old value.
    state = state |> Core.command({:write, 3, "Third notice"})
    assert state.writes_issued == 3

    fresh_payload = get_in(state.nodes, [3, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 1, fresh_payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    known = get_in(state.nodes, [1, :known, state.origin])
    assert known.value == "Third notice"
    assert known.version == 3
  end

  test "a write of the same value still moves the frontier forward" do
    state = Scenarios.fetch(:bulletin) |> Core.new()
    state = state |> Core.command({:write, 1, "Repeat"}) |> Core.command({:write, 2, "Repeat"})

    assert state.writes_issued == 2
    assert state.register_value == "Repeat"

    fresh = get_in(state.nodes, [2, :known, state.origin])
    assert fresh.value == "Repeat"
    assert fresh.version == 2
  end

  # ---------------------------------------------------------------------------
  # faults and register state
  # ---------------------------------------------------------------------------

  test "crashing a register node drops its value" do
    state = Scenarios.fetch(:bulletin) |> Core.new()

    state = %{state | queue: []}
    state = Core.command(state, {:write, 7, "Temp"})
    assert get_in(state.nodes, [7, :known, state.origin]).value == "Temp"

    state = Core.command(state, {:crash, 7})
    assert get_in(state.nodes, [7, :known, state.origin]).value == nil
    refute state.nodes[7].up
  end

  test "a permanently crashed register node blocks convergence" do
    scenario = %Scenario{
      Scenarios.bulletin()
      | topology: SignalGarden.Sim.Topology.line(6),
        seed: 5,
        origin: 1,
        fault_schedule: [%{at: 100, action: {:write, 1, "Notice"}, label: "write"}]
    }

    state = Core.new(scenario)
    state = Core.command(state, {:crash, 6})
    state = run_to_converge(state)

    refute state.status == :converged
    assert state.nodes[6].up == false
  end

  test "restarting a register node lets it re-learn the latest value" do
    state = run_to_completion(:bulletin)
    state = Core.command(state, {:crash, 5})
    state = Core.command(state, {:restart, 5})

    assert get_in(state.nodes, [5, :known, state.origin]).value == nil

    state = run_to_converge(state)
    known = get_in(state.nodes, [5, :known, state.origin])
    assert known.value == "All systems nominal"
    assert known.version == 5
  end

  test "write faults appear in the event log" do
    state = Scenarios.fetch(:bulletin) |> Core.new()
    state = Core.command(state, {:write, 3, "Logged"})

    assert Enum.any?(state.event_log, &(&1.kind == :wrote and &1.value == "Logged"))
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "the snapshot exposes register fields" do
    state = Scenarios.fetch(:bulletin) |> Core.new() |> Core.command({:write, 1, "Status"})
    snap = Core.snapshot(state)

    assert snap.mode == :register
    assert snap.register_value == "Status"
    assert snap.register_writes == 1

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
