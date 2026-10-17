defmodule SignalGarden.Sim.PNCounterCoreTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, PNCounter, Scenario}

  test ~S(the ledger scenario converges to its signed balance) do
    state = run_to_converge(Scenarios.ledger())

    assert state.status == :converged
    assert state.pn_adjustments_issued == 5
    assert state.pn_adjustments_total == 1
    assert PNCounter.value(state.pn_counter) == 1
    assert Enum.sum(Map.values(state.pn_counter.positive)) == 8
    assert Enum.sum(Map.values(state.pn_counter.negative)) == 7

    for node_id <- state.topology.nodes do
      known = get_in(state.nodes, [node_id, :known, state.origin])
      assert PNCounter.equivalent?(known, state.pn_counter)
    end
  end

  test ~S(two runs keep the same cells and event trace) do
    first = run_to_converge(Scenarios.ledger())
    second = run_to_converge(Scenarios.ledger())

    assert first.convergence_time == second.convergence_time
    assert first.pn_counter == second.pn_counter
    assert first.event_log == second.event_log
  end

  test ~S(a message merges positive and negative cells independently) do
    state = Core.new(Scenarios.ledger())
    state = state |> Core.command({:adjust, 1, 5}) |> Core.command({:adjust, 2, -2})
    payload = get_in(state.nodes, [1, :known, state.origin])
    state = %{state | queue: [{1, state.seq + 1, {:deliver, 2, payload}}]}

    {state, 1} = Core.step(state, 1)
    merged = get_in(state.nodes, [2, :known, state.origin])

    assert merged == %{positive: %{1 => 5}, negative: %{2 => 2}}
    assert PNCounter.value(merged) == 3
  end

  test ~S(zero and unsupported adjustments do not change the state) do
    state = Core.new(Scenarios.ledger())
    assert Core.command(state, {:adjust, 1, 0}) == state

    rumor = Core.new(Scenarios.ring())
    assert Core.command(rumor, {:adjust, 1, 5}) == rumor
  end

  test ~S(a manual adjustment after convergence starts a new run) do
    state = run_to_converge(Scenarios.ledger())
    state = Core.command(state, {:adjust, 2, -3})

    assert state.status == :idle
    assert state.convergence_time == nil
    assert state.pn_adjustments_total == -2

    state = run_to_converge(state)
    assert state.status == :converged
    assert PNCounter.value(get_in(state.nodes, [2, :known, state.origin])) == -2
  end

  test ~S(the snapshot exposes signed counter evidence) do
    state =
      Scenarios.ledger()
      |> Core.new()
      |> Core.command({:adjust, 1, 5})
      |> Core.command({:adjust, 2, -2})

    snapshot = Core.snapshot(state)

    assert snapshot.mode == :pn_counter
    assert snapshot.pn_adjustments == 2
    assert snapshot.pn_total == 3
    assert snapshot.pn_positive == 5
    assert snapshot.pn_negative == 2
    assert Enum.find(snapshot.nodes, &(&1.id == 1)).value == 5
    assert Enum.find(snapshot.nodes, &(&1.id == 2)).value == -2
  end

  test ~S(the signed counter survives a node restart) do
    state = run_to_converge(Scenarios.ledger())
    state = state |> Core.command({:crash, 5}) |> Core.command({:restart, 5})

    assert get_in(state.nodes, [5, :known, state.origin]) == PNCounter.new()
    state = run_to_converge(state)
    assert PNCounter.equivalent?(get_in(state.nodes, [5, :known, state.origin]), state.pn_counter)
  end

  test ~S(a restarted writer preserves its cell on a later adjustment) do
    state = run_to_converge(Scenarios.ledger())
    state = state |> Core.command({:crash, 1}) |> Core.command({:restart, 1})
    state = Core.command(state, {:adjust, 1, 2})
    state = run_to_converge(state)

    assert state.pn_adjustments_total == 3
    assert state.pn_counter.positive == %{1 => 7, 9 => 3}
    assert state.pn_counter.negative == %{1 => 1, 4 => 4, 6 => 2}
    assert PNCounter.equivalent?(get_in(state.nodes, [1, :known, state.origin]), state.pn_counter)
  end

  defp run_to_converge(%Scenario{} = scenario), do: run_to_converge(Core.new(scenario))

  defp run_to_converge(%Core{} = state) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..4_000, state, fn _, acc ->
      {acc, _} = Core.step(acc, 50)

      if acc.status == :converged do
        {:halt, acc}
      else
        {:cont, acc}
      end
    end)
  end
end
