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

  test "the sample counter file loads and converges to the expected total" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "counter.json"])
    json = File.read!(path)
    assert {:ok, scenario} = ScenarioCodec.decode(json)
    assert scenario.name == "Grow-only counter"
    assert scenario.mode == :counter

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
    assert state.increments_total == 9
  end

  test "the sample set file loads and converges to the full collection" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "set.json"])
    json = File.read!(path)
    assert {:ok, scenario} = ScenarioCodec.decode(json)
    assert scenario.name == "Guest list"
    assert scenario.mode == :set

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
    assert MapSet.size(state.elements) == 5
  end

  test "the sample register file loads and converges to the last notice" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "register.json"])
    json = File.read!(path)
    assert {:ok, scenario} = ScenarioCodec.decode(json)
    assert scenario.name == "Bulletin board"
    assert scenario.mode == :register

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
    assert state.writes_issued == 5
    assert state.register_value == "All systems nominal"
  end

  test "crash and restart faults round-trip through JSON" do
    scenario = Scenarios.crash()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:crash, 4} in Enum.map(decoded.fault_schedule, & &1.action)
    assert {:restart, 9} in Enum.map(decoded.fault_schedule, & &1.action)
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

  test "counter mode and increment faults round-trip through JSON" do
    scenario = Scenarios.counter()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.mode == :counter
    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:increment, 1, 2} in Enum.map(decoded.fault_schedule, & &1.action)
  end

  test "set mode and add faults round-trip through JSON" do
    scenario = Scenarios.guest_list()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.mode == :set
    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:add, 1, "Ada"} in Enum.map(decoded.fault_schedule, & &1.action)
  end

  test "register mode and write faults round-trip through JSON" do
    scenario = Scenarios.bulletin()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.mode == :register
    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:write, 1, "System online"} in Enum.map(decoded.fault_schedule, & &1.action)
    assert decoded.id == :bulletin
  end

  test "an exported register scenario replays to the same trace" do
    scenario = Scenarios.bulletin()
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
    assert run.(scenario).register_value == run.(decoded).register_value
    assert run.(scenario).event_log == run.(decoded).event_log
  end

  test "an exported set scenario replays to the same trace" do
    scenario = Scenarios.guest_list()
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
    assert run.(scenario).elements == run.(decoded).elements
  end

  test "link cuts round-trip through JSON" do
    scenario = %{Scenarios.line() | link_cuts: [{2, 1}, {3, 4}]}
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.link_cuts == [{1, 2}, {3, 4}]
  end

  test "cut link and heal link faults round-trip through JSON" do
    scenario = Scenarios.cut()
    json = ScenarioCodec.encode(scenario)
    assert {:ok, decoded} = ScenarioCodec.decode(json)

    assert decoded.id == :cut
    assert decoded.link_cuts == []
    assert decoded.fault_schedule == scenario.fault_schedule
    assert {:cut, {1, 2}} in Enum.map(decoded.fault_schedule, & &1.action)
    assert {:heal_link, {11, 12}} in Enum.map(decoded.fault_schedule, & &1.action)
  end

  test "an exported broken link scenario replays to the same trace" do
    scenario = Scenarios.cut()
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
    assert run.(scenario).event_log == run.(decoded).event_log
  end

  test "link cuts on unknown endpoints are rejected" do
    scenario = %{Scenarios.line() | link_cuts: [{1, 99}]}
    json = ScenarioCodec.encode(scenario)
    assert {:error, {:invalid_field, "link_cuts"}} = ScenarioCodec.decode(json)
  end

  test "a decoded counter scenario converges to the same total" do
    scenario = Scenarios.counter()
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

    assert run.(scenario).increments_total == run.(decoded).increments_total
    assert run.(scenario).convergence_time == run.(decoded).convergence_time
  end

  test "files without a mode field decode as rumor mode" do
    scenario = %{Scenarios.line() | id: :custom_demo, name: "Legacy"}
    json = ScenarioCodec.encode(scenario)
    json = String.replace(json, ~s("mode": "rumor",), "")
    assert {:ok, decoded} = ScenarioCodec.decode(json)
    assert decoded.mode == :rumor
  end
end
