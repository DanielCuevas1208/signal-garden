defmodule SignalGarden.Sim.CounterTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Scenario, Topology}

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "a grow-only counter scenario converges to the expected total" do
    state = run_to_completion(:counter)

    assert state.status == :converged
    assert state.increments_total == 9
    assert state.increments_issued == 5

    totals =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).cells
        |> Map.values()
        |> Enum.sum()
      end)

    assert Enum.uniq(totals) == [9]
  end

  test "two counter runs converge at the same logical clock" do
    a = run_to_completion(:counter)
    b = run_to_completion(:counter)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
  end

  test "the run does not converge before all scheduled writes are issued" do
    state = Scenarios.fetch(:counter) |> Core.new()
    {state, _} = Core.step(state, 500)

    refute state.status == :converged
    assert MapSet.size(state.informed) == 0
  end

  # ---------------------------------------------------------------------------
  # increment commands
  # ---------------------------------------------------------------------------

  test "a manual increment raises the total and the writing node's total" do
    state = Scenarios.fetch(:counter) |> Core.new()
    state = Core.command(state, {:increment, 3, 1})

    assert state.increments_total == 1
    assert state.increments_issued == 1

    cells = get_in(state.nodes, [3, :known, state.origin]).cells
    assert cells == %{3 => 1}
  end

  test "increment commands are ignored in rumor mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:increment, 2, 5})

    assert state.increments_total == 0
    assert state.increments_issued == 0
  end

  test "a manual increment after convergence re-arms the run" do
    state = run_to_completion(:counter)
    assert state.status == :converged

    state = Core.command(state, {:increment, 2, 1})
    assert state.status == :idle
    assert state.increments_total == 10

    state = run_to_converge(state)
    assert state.status == :converged

    totals =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).cells
        |> Map.values()
        |> Enum.sum()
      end)

    assert Enum.uniq(totals) == [10]
  end

  test "a scheduled increment does not move the convergence target" do
    scenario = %Scenario{
      Scenarios.counter()
      | fault_schedule: [%{at: 10, action: {:increment, 2, 3}, label: "write"}]
    }

    state = Core.new(scenario)
    state = step_n(state, 20)

    assert state.increments_issued == 1
    assert state.increment_target == 1
    assert state.increments_total == 3
  end

  # ---------------------------------------------------------------------------
  # merge semantics
  # ---------------------------------------------------------------------------

  test "delivering a message merges cells with element-wise max" do
    state = Scenarios.fetch(:counter) |> Core.new()

    # Node 1 writes twice, node 2 writes once.
    state = state |> Core.command({:increment, 1, 2}) |> Core.command({:increment, 2, 1})

    # Hand node 1's cells straight to node 2 as an in-flight message.
    payload = get_in(state.nodes, [1, :known, state.origin])
    queue = [{1, state.seq + 1, {:deliver, 2, payload}}]
    state = %{state | queue: queue}
    {state, _} = Core.step(state, 1)

    cells = get_in(state.nodes, [2, :known, state.origin]).cells
    assert cells == %{1 => 2, 2 => 1}
  end

  test "a node only needs the cells of writers, not a single origin value" do
    scenario = %Scenario{Scenarios.counter() | origin: 6}
    state = Core.new(scenario)

    state = Core.command(state, {:increment, 1, 1})
    state = Core.command(state, {:increment, 4, 2})

    cells = get_in(state.nodes, [4, :known, state.origin]).cells
    assert cells == %{4 => 2}
    assert get_in(state.nodes, [1, :known, state.origin]).cells[1] == 1
  end

  # ---------------------------------------------------------------------------
  # faults and counter state
  # ---------------------------------------------------------------------------

  test "crashing a counter node drops its cells" do
    state = Scenarios.fetch(:counter) |> Core.new()

    # Give node 7 a cell, then take it down.
    state = %{state | queue: []}
    state = Core.command(state, {:increment, 7, 4})
    assert get_in(state.nodes, [7, :known, state.origin]).cells == %{7 => 4}

    state = Core.command(state, {:crash, 7})
    assert get_in(state.nodes, [7, :known, state.origin]).cells == %{}
    refute state.nodes[7].up
  end

  test "a permanently crashed counter node blocks convergence" do
    scenario = %Scenario{
      Scenarios.counter()
      | topology: Topology.line(6),
        seed: 5,
        origin: 1,
        fault_schedule: [%{at: 100, action: {:increment, 1, 1}, label: "write"}]
    }

    state = Core.new(scenario)
    state = Core.command(state, {:crash, 6})
    state = run_to_converge(state)

    refute state.status == :converged
    assert state.nodes[6].up == false
  end

  test "restarting a counter node lets it re-learn the total" do
    state = run_to_completion(:counter)
    state = Core.command(state, {:crash, 5})
    state = Core.command(state, {:restart, 5})

    assert get_in(state.nodes, [5, :known, state.origin]).cells == %{}

    state = run_to_converge(state)
    cells = get_in(state.nodes, [5, :known, state.origin]).cells
    assert Enum.sum(Map.values(cells)) == 9
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "the snapshot exposes counter fields" do
    state = Scenarios.fetch(:counter) |> Core.new() |> Core.command({:increment, 1, 1})
    snap = Core.snapshot(state)

    assert snap.mode == :counter
    assert snap.counter_total == 1
    assert snap.counter_writes == 1

    node = Enum.find(snap.nodes, &(&1.id == 1))
    assert node.value == 1
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
