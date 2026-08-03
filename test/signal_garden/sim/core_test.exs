defmodule SignalGarden.Sim.CoreTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Sim.Core
  alias SignalGarden.Sim.Scenario
  alias SignalGarden.Scenarios

  # ---------------------------------------------------------------------------
  # determinism
  # ---------------------------------------------------------------------------

  test "two runs of the same scenario converge at the same logical clock" do
    a = run_to_completion(:ring)
    b = run_to_completion(:ring)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
  end

  test "the event log is identical across runs" do
    a = run_to_completion(:lossy)
    b = run_to_completion(:lossy)

    assert a.event_log == b.event_log
  end

  test "different seeds produce different convergence traces" do
    a = run_to_completion(:ring)

    other =
      %Scenario{Scenarios.ring() | seed: 999}
      |> Core.new()
      |> run_to_converge()

    refute a.convergence_time == other.convergence_time
  end

  # ---------------------------------------------------------------------------
  # crash and restart
  # ---------------------------------------------------------------------------

  test "crashing a node drops its knowledge and stops its gossip" do
    state = Core.new(Scenarios.fetch(:line))
    state = Core.command(state, {:crash, 2})

    assert state.nodes[2].up == false
    assert state.nodes[2].informed == false
    assert get_in(state.nodes, [2, :known, state.origin]).version == 0
    refute 2 in state.informed
  end

  test "restarting a node brings it back with empty state and reschedules gossip" do
    state = Core.new(Scenarios.fetch(:line))
    state = Core.command(state, {:crash, 2})
    state = Core.command(state, {:restart, 2})

    assert state.nodes[2].up == true
    assert state.nodes[2].informed == false
    assert get_in(state.nodes, [2, :known, state.origin]).version == 0

    assert Enum.any?(state.queue, fn
             {_, _, {:gossip, 2}} -> true
             _ -> false
           end)
  end

  test "a permanently crashed node blocks convergence" do
    scenario = Scenarios.fetch(:ring)
    state = Core.new(scenario)
    {state, _} = Core.step(state, 200)
    assert 7 in state.informed

    state = Core.command(state, {:crash, 7})
    state = step_n(state, 4_000)

    refute state.status == :converged
    refute 7 in state.informed
    assert state.nodes[7].up == false
  end

  test "crashing then restarting lets the network converge again" do
    scenario = Scenarios.fetch(:ring)

    state =
      Core.new(scenario)
      |> step_n(200)
      |> Core.command({:crash, 7})
      |> Core.command({:crash, 8})
      |> Core.command({:restart, 7})
      |> Core.command({:restart, 8})
      |> run_to_converge()

    assert state.status == :converged
    assert state.nodes[7].up == true
    assert state.nodes[8].up == true
    assert 7 in state.informed
    assert 8 in state.informed
  end

  test "crash and restart faults appear in the event log" do
    state = Core.new(Scenarios.fetch(:ring))
    state = Core.command(state, {:crash, 7})
    assert :crashed in Enum.map(state.event_log, & &1.kind)

    state = Core.command(state, {:restart, 7})
    assert :restarted in Enum.map(state.event_log, & &1.kind)
  end

  test "the crash scenario replays to the same trace" do
    a = run_to_completion(:crash)
    b = run_to_completion(:crash)

    assert a.convergence_time == b.convergence_time
    assert a.event_log == b.event_log
    assert a.history == b.history
  end

  # ---------------------------------------------------------------------------
  # convergence
  # ---------------------------------------------------------------------------

  test "a healthy network always converges" do
    completed = run_to_completion(:grid)
    assert completed.status == :converged
    assert completed.convergence_time != nil
    assert MapSet.size(completed.informed) == map_size(completed.nodes)
  end

  test "running fewer steps than needed keeps the network incomplete" do
    state = Core.new(Scenarios.fetch(:grid))
    {state, _} = Core.step(state, 1)
    assert MapSet.size(state.informed) < map_size(state.nodes)
    assert state.convergence_time == nil
  end

  # ---------------------------------------------------------------------------
  # partitions
  # ---------------------------------------------------------------------------

  test "a permanent partition leaves the network non-converged" do
    scenario = Scenarios.fetch(:line)

    state =
      Core.new(scenario)
      |> Core.command({:assign, scenario.origin, 0})
      |> put_all_other_in_group_one(scenario)
      |> step_n(4_000)

    refute state.status == :converged
    assert state.convergence_time == nil
    assert MapSet.size(state.informed) == 1
  end

  test "healing partitions lets the network resume convergence" do
    scenario = Scenarios.fetch(:line)

    state =
      Core.new(scenario)
      |> Core.command({:assign, scenario.origin, 0})
      |> put_all_other_in_group_one(scenario)
      |> step_n(4_000)
      |> Core.command({:merge, :all})
      |> run_to_converge()

    assert state.status == :converged
  end

  test "toggling a node group flips its partition membership" do
    state = Core.new(Scenarios.fetch(:line))

    state = Core.command(state, {:toggle_partition, 2})
    assert state.partitions[2] == 1

    state = Core.command(state, {:toggle_partition, 2})
    assert Map.get(state.partitions, 2, 0) == 0
  end

  # ---------------------------------------------------------------------------
  # delay and loss
  # ---------------------------------------------------------------------------

  test "higher delay pushes convergence later in logical time" do
    fast = run_to_completion(:line)

    slow =
      %Scenario{Scenarios.line() | delay_ms: {500, 500}}
      |> Core.new()
      |> run_to_converge()

    assert slow.convergence_time > fast.convergence_time
  end

  test "lossy scenarios still converge and record dropped messages" do
    state = run_to_completion(:lossy)
    assert state.status == :converged
    assert state.dropped > 0
  end

  # ---------------------------------------------------------------------------
  # snapshot shape
  # ---------------------------------------------------------------------------

  test "a snapshot lists every node and edge" do
    scenario = Scenarios.fetch(:line)
    state = Core.new(scenario)
    snap = Core.snapshot(state)

    assert length(snap.nodes) == length(scenario.topology.nodes)
    assert length(snap.edges) == length(scenario.topology.edges)
    assert snap.status == :idle
    assert snap.reached == 1
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

  defp put_all_other_in_group_one(state, scenario) do
    Enum.reduce(scenario.topology.nodes, state, fn id, acc ->
      if id == scenario.origin, do: acc, else: Core.command(acc, {:assign, id, 1})
    end)
  end
end
