defmodule SignalGarden.Sim.MVRegisterTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Core

  test "the conflict board converges with both concurrent values" do
    state = run_to_completion(:conflict_board)

    assert state.status == :converged
    assert state.writes_issued == 2

    assert SignalGarden.Sim.MultiValueRegister.values(%{
             entries: state.mv_entries,
             context: state.mv_context
           }) == ["blue", "green"]

    assert map_size(state.mv_entries) == 2

    entries =
      Enum.map(state.topology.nodes, fn id ->
        get_in(state.nodes, [id, :known, state.origin]).entries
      end)

    assert Enum.all?(entries, &(&1 == state.mv_entries))
  end

  test "two conflict board runs produce the same trace" do
    a = run_to_completion(:conflict_board)
    b = run_to_completion(:conflict_board)

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.event_log == b.event_log
    assert a.mv_entries == b.mv_entries
  end

  test "a manual write starts a new multi-value branch" do
    state = Scenarios.fetch(:conflict_board) |> Core.new()
    state = Core.command(state, {:write, 3, "blue"})
    state = Core.command(state, {:write, 8, "green"})

    assert state.writes_issued == 2
    assert map_size(state.mv_entries) == 2
    assert get_in(state.nodes, [3, :known, state.origin]).entries |> map_size() == 1
    assert get_in(state.nodes, [8, :known, state.origin]).entries |> map_size() == 1
  end

  test "a later write removes values observed by its writer" do
    state = Scenarios.fetch(:conflict_board) |> Core.new()
    state = Core.command(state, {:write, 1, "blue"})
    state = Core.command(state, {:write, 2, "green"})
    payload = get_in(state.nodes, [1, :known, state.origin])
    state = %{state | queue: [{1, state.seq + 1, {:deliver, 2, payload}}]}
    {state, _} = Core.step(state, 1)
    state = Core.command(state, {:write, 2, "violet"})

    assert SignalGarden.Sim.MultiValueRegister.values(%{
             entries: state.mv_entries,
             context: state.mv_context
           }) == ["violet"]
  end

  test "write commands are ignored outside multi-value register mode" do
    state = Scenarios.fetch(:ring) |> Core.new()
    state = Core.command(state, {:write, 2, "ignored"})

    assert state.writes_issued == 0
    assert state.mv_entries == %{}
  end

  test "a crashed node loses its branches and can re-learn them" do
    state = run_to_completion(:conflict_board)
    state = Core.command(state, {:crash, 5})
    assert get_in(state.nodes, [5, :known, state.origin]).entries == %{}

    state = Core.command(state, {:restart, 5}) |> run_to_converge()
    assert get_in(state.nodes, [5, :known, state.origin]).entries == state.mv_entries
  end

  test "the snapshot exposes conflict values and branch metadata" do
    state =
      Scenarios.fetch(:conflict_board)
      |> Core.new()
      |> Core.command({:write, 1, "blue"})
      |> Core.command({:write, 2, "green"})

    snapshot = Core.snapshot(state)

    assert snapshot.mode == :mv_register
    assert snapshot.mv_writes == 2
    assert snapshot.mv_conflicts == 2
    assert snapshot.mv_values == ["blue", "green"]
    assert Enum.map(snapshot.mv_entries, & &1.value) == ["blue", "green"]
  end

  defp run_to_completion(id), do: Scenarios.fetch(id) |> Core.new() |> run_to_converge()

  defp run_to_converge(%Core{} = state), do: await(state, :converged, 200_000)

  defp await(%Core{} = state, target, budget) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..div(budget, 50)//1, state, fn _, acc ->
      {acc, _} = Core.step(acc, 50)
      if acc.status == target, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
