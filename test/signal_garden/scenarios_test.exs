defmodule SignalGarden.ScenariosTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Core

  test "every catalog entry has a unique id and a topology" do
    ids = Enum.map(Scenarios.catalog(), & &1.id)
    assert ids == Enum.uniq(ids)
    assert length(ids) >= 5

    for scenario <- Scenarios.catalog() do
      assert scenario.topology.nodes != []
      assert scenario.origin in scenario.topology.nodes
    end
  end

  test "every non-partitioned scenario converges within a budget" do
    for scenario <- Scenarios.catalog(), scenario.fault_schedule == [] do
      state = Core.new(scenario)
      state = await_converge(state, 200_000)
      assert state.status == :converged, "scenario #{scenario.id} did not converge"
    end
  end

  test "the Broken link scenario converges once its links heal" do
    scenario = Scenarios.fetch(:cut)
    state = await_converge(Core.new(scenario), 200_000)
    assert state.status == :converged
    assert state.dropped > 0
  end

  test "the Guest list scenario converges to the full set" do
    scenario = Scenarios.fetch(:guest_list)
    state = await_converge(Core.new(scenario), 200_000)

    assert state.status == :converged
    assert state.adds_issued == 5
    assert MapSet.size(state.elements) == 5

    for node_id <- scenario.topology.nodes do
      elements = get_in(state.nodes, [node_id, :known, state.origin]).elements
      assert MapSet.equal?(elements, state.elements), "node #{node_id} misses elements"
    end
  end

  test "the Shared roster scenario converges to the surviving members" do
    scenario = Scenarios.fetch(:roster)
    state = await_converge(Core.new(scenario), 200_000)

    assert state.status == :converged
    assert state.orset_ops_issued == 6
    assert state.orset_elements == MapSet.new(["Alan", "Edsger"])

    for node_id <- scenario.topology.nodes do
      store = get_in(state.nodes, [node_id, :known, state.origin]).store

      members =
        store
        |> Enum.filter(fn {_element, %{adds: adds, removes: removes}} ->
          MapSet.difference(adds, removes) != MapSet.new()
        end)
        |> Enum.map(fn {element, _tags} -> element end)
        |> MapSet.new()

      assert members == state.orset_elements, "node #{node_id} holds a stale roster"
    end
  end

  test "the Bulletin board scenario converges to the last notice" do
    scenario = Scenarios.fetch(:bulletin)
    state = await_converge(Core.new(scenario), 200_000)

    assert state.status == :converged
    assert state.writes_issued == 5
    assert state.register_value == "All systems nominal"

    for node_id <- scenario.topology.nodes do
      known = get_in(state.nodes, [node_id, :known, state.origin])
      assert known.value == "All systems nominal", "node #{node_id} holds an old notice"
      assert known.version == 5, "node #{node_id} holds an old version"
    end
  end

  test "the Service board scenario converges to the newest status per service" do
    scenario = Scenarios.fetch(:service_board)
    state = await_converge(Core.new(scenario), 200_000)

    assert state.status == :converged
    assert state.writes_issued == 5
    assert state.map_fields["db"].value == "operational"
    assert state.map_fields["db"].version == 5

    expected = state.map_fields

    for node_id <- scenario.topology.nodes do
      fields = get_in(state.nodes, [node_id, :known, state.origin]).fields
      assert fields == expected, "node #{node_id} holds a stale service map"
    end
  end

  defp await_converge(state, budget) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..div(budget, 50)//1, state, fn _, acc ->
      {acc, _} = Core.step(acc, 50)
      if acc.status == :converged, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
