defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Replay, Scenario, ScenarioCodec}

  # ---------------------------------------------------------------------------
  # resolve
  # ---------------------------------------------------------------------------

  test "resolve accepts an atom id, a name string, and a scenario struct" do
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve(:ring)
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve("ring")
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve("Ring")

    scenario = Scenarios.grid()
    assert {:ok, ^scenario} = Replay.resolve(scenario)
  end

  test "resolve accepts a path to a scenario file" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "counter.json"])
    assert {:ok, %Scenario{id: :counter, mode: :counter}} = Replay.resolve(path)
  end

  test "resolve accepts inline scenario JSON" do
    json = ScenarioCodec.encode(Scenarios.line())
    assert {:ok, %Scenario{name: "Line"}} = Replay.resolve(json)
  end

  test "resolve rejects unknown sources" do
    assert {:error, {:unknown_scenario, :nope}} = Replay.resolve(:nope)
    assert {:error, {:unknown_scenario, "nope"}} = Replay.resolve("nope")
  end

  # ---------------------------------------------------------------------------
  # run
  # ---------------------------------------------------------------------------

  test "a full replay converges and returns a complete trace" do
    {:ok, result} = Replay.run(:ring)

    assert result.status == :converged
    assert result.convergence_time > 0
    assert result.reached == result.total
    assert result.trace != []
    assert length(result.trace) == result.hops

    assert Enum.all?(result.trace, fn entry ->
             entry.kind in [
               :deliver,
               :dropped_loss,
               :dropped_partition,
               :crashed,
               :restarted,
               :increment
             ]
           end)
  end

  test "two full replays produce byte-identical traces" do
    {:ok, a} = Replay.run(:lossy)
    {:ok, b} = Replay.run(:lossy)

    assert a.trace == b.trace
    assert a.history == b.history
    assert a.convergence_time == b.convergence_time
    assert a.dropped == b.dropped
  end

  test "a counter scenario replays to the expected total" do
    {:ok, result} = Replay.run(:counter)
    assert result.status == :converged
    assert result.counter_total == 9
    assert result.scenario.mode == :counter
  end

  test "the steps limit stops a run before convergence" do
    {:ok, result} = Replay.run(:ring, steps: 50)
    # the counter includes the initial t=0 record plus the 50 processed events
    assert result.steps == 51
    refute result.status == :converged
  end

  test "the run carries scenario metadata and counters" do
    {:ok, result} = Replay.run(:split)

    assert result.scenario.name == "Healing partition"
    assert result.scenario.seed == 7
    assert result.total == 14
    assert Enum.any?(result.trace, &(&1.kind == :dropped_partition))
  end

  test "a permanent partition exhausts the run" do
    scenario = %Scenario{Scenarios.line() | partitions: %{2 => 1, 3 => 1, 4 => 1}}
    {:ok, result} = Replay.run(scenario)
    refute result.status == :converged
  end

  # ---------------------------------------------------------------------------
  # verify
  # ---------------------------------------------------------------------------

  test "verify replays twice and confirms determinism" do
    {:ok, report} = Replay.verify(:ring)
    assert report.equal
    assert report.convergence_time_equal
    assert report.trace_equal
    assert report.history_equal
  end

  # ---------------------------------------------------------------------------
  # formatting
  # ---------------------------------------------------------------------------

  test "format_line renders each event kind" do
    assert Replay.format_line(%{t: 12, kind: :deliver, from: 1, to: 2, partition: false}) ==
             "T=12 1 -> 2 delivered"

    assert Replay.format_line(%{t: 9, kind: :dropped_loss, from: 3, to: 4, partition: false}) ==
             "T=9 3 -> 4 dropped (loss)"

    assert Replay.format_line(%{t: 5, kind: :crashed, from: 2, to: nil, partition: false}) ==
             "T=5 node 2 crashed"

    assert Replay.format_line(%{t: 7, kind: :increment, from: 1, to: nil, amount: 3}) ==
             "T=7 node 1 wrote +3"
  end

  test "format_trace honours the limit" do
    {:ok, result} = Replay.run(:ring)
    assert length(Replay.format_trace(result)) == length(result.trace)
    assert length(Replay.format_trace(result, limit: 3)) == 3
  end

  test "format_summary and format_determinism render text" do
    {:ok, result} = Replay.run(:ring)
    assert Replay.format_summary(result) =~ "Replay: Ring (ring)"

    {:ok, report} = Replay.verify(:ring)
    assert Replay.format_determinism(report) =~ "convergence_time equal = true"
  end

  test "to_json_map round-trips through Jason" do
    {:ok, result} = Replay.run(:counter)
    json = Jason.encode!(Replay.to_json_map(result))
    map = Jason.decode!(json)

    assert map["status"] == "converged"
    assert map["scenario"]["id"] == "counter"
    assert map["counter_total"] == 9
    assert length(map["trace"]) == length(result.trace)
    assert Enum.all?(map["trace"], fn entry -> is_binary(entry["kind"]) end)
  end
end
