defmodule SignalGarden.Sim.ScenarioCodecTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, ScenarioCodec}

  test "every catalog scenario round-trips through JSON" do
    for scenario <- Scenarios.catalog() do
      json = ScenarioCodec.encode(scenario)
      assert {:ok, decoded} = ScenarioCodec.decode(json)
      assert decoded.id == scenario.id
      assert decoded.name == scenario.name
      assert decoded.seed == scenario.seed
      assert decoded.mode == scenario.mode
      assert decoded.topology.nodes == scenario.topology.nodes
      assert decoded.topology.edges == scenario.topology.edges
      assert decoded.fault_schedule == scenario.fault_schedule
    end
  end

  test "a decoded scenario reproduces the same convergence trace" do
    scenario = Scenarios.ring()
    json = ScenarioCodec.encode(scenario)
    {:ok, decoded} = ScenarioCodec.decode(json)

    run = fn s ->
      s
      |> Core.new()
      |> Core.command({:set_status, :running})
      |> then(fn state ->
        Enum.reduce_while(1..10_000, state, fn _, acc ->
          {acc, _} = Core.step(acc, 200)
          if acc.status in [:converged, :exhausted], do: {:halt, acc}, else: {:cont, acc}
        end)
      end)
    end

    a = run.(scenario)
    b = run.(decoded)

    assert a.convergence_time == b.convergence_time
    assert a.hops == b.hops
    assert a.dropped == b.dropped
    assert a.steps == b.steps
  end

  test "unknown ids become :imported" do
    scenario = Scenarios.line()
    json = ScenarioCodec.encode(%{scenario | id: :custom_demo, name: "Custom demo"})
    assert {:ok, decoded} = ScenarioCodec.decode(json)
    assert decoded.id == :imported
    assert decoded.name == "Custom demo"
  end

  test "invalid JSON returns a structured error" do
    assert {:error, {:invalid_json, _}} = ScenarioCodec.decode("{not json")
  end

  test "missing format version is rejected" do
    assert {:error, :missing_format} = ScenarioCodec.decode(~s({"name":"x"}))
  end

  test "the sample ring file loads and converges" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    json = File.read!(path)
    assert {:ok, scenario} = ScenarioCodec.decode(json)
    assert scenario.name == "Ring"

    state =
      scenario
      |> Core.new()
      |> Core.command({:set_status, :running})
      |> then(fn state ->
        Enum.reduce_while(1..10_000, state, fn _, acc ->
          {acc, _} = Core.step(acc, 200)
          if acc.status in [:converged, :exhausted], do: {:halt, acc}, else: {:cont, acc}
        end)
      end)

    assert state.status == :converged
  end

  test "crash and restart faults round-trip through JSON" do
    scenario = Scenarios.crash()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:crash, 4} in Enum.map(decoded.fault_schedule, & &1.action)
    assert {:restart, 9} in Enum.map(decoded.fault_schedule, & &1.action)
  end

  test "counter scenarios round-trip their mode and increment faults" do
    scenario = Scenarios.counter_split()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.mode == :counter
    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:increment, 6} in Enum.map(decoded.fault_schedule, & &1.action)
  end

  test "a file without a mode field loads as rumor" do
    json = ScenarioCodec.encode(%{Scenarios.line() | mode: :rumor})
    json = String.replace(json, ~s("mode": "rumor",), "")
    assert {:ok, decoded} = ScenarioCodec.decode(json)
    assert decoded.mode == :rumor
  end

  test "an unknown mode is rejected" do
    json = ScenarioCodec.encode(%{Scenarios.line() | mode: :rumor})
    json = String.replace(json, ~s("mode": "rumor",), ~s("mode": "banana",))
    assert {:error, {:invalid_field, "mode"}} = ScenarioCodec.decode(json)
  end

  test "an exported crash scenario replays to the same trace" do
    scenario = Scenarios.crash()
    json = ScenarioCodec.encode(scenario)
    {:ok, decoded} = ScenarioCodec.decode(json)

    run = fn s ->
      s
      |> Core.new()
      |> Core.command({:set_status, :running})
      |> then(fn state ->
        Enum.reduce_while(1..10_000, state, fn _, acc ->
          {acc, _} = Core.step(acc, 200)
          if acc.status in [:converged, :exhausted], do: {:halt, acc}, else: {:cont, acc}
        end)
      end)
    end

    assert run.(scenario).convergence_time == run.(decoded).convergence_time
  end
end
