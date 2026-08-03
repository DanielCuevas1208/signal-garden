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

  test "the restart scenario schedules a crash and a restart" do
    actions = Enum.map(Scenarios.restart().fault_schedule, & &1.action)
    assert actions == [{:crash, 4}, {:restart, 4}]
  end

  defp await_converge(state, budget) do
    state = Core.command(state, {:set_status, :running})

    Enum.reduce_while(1..div(budget, 50)//1, state, fn _, acc ->
      {acc, _} = Core.step(acc, 50)
      if acc.status == :converged, do: {:halt, acc}, else: {:cont, acc}
    end)
  end
end
