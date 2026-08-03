defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Core, Replay, Scenario}

  # ---------------------------------------------------------------------------
  # resolution
  # ---------------------------------------------------------------------------

  test "a catalog id resolves to its scenario" do
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve(:ring)
    assert {:ok, %Scenario{id: :counter}} = Replay.resolve("counter")
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve("ring.json")
  end

  test "a scenario file resolves by path" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    assert {:ok, %Scenario{name: "Ring"}} = Replay.resolve(path)
  end

  test "an unknown target returns a structured error" do
    assert {:error, {:unknown_scenario, :nope}} = Replay.resolve(:nope)
    assert {:error, {:unknown_target, "nope"}} = Replay.resolve("nope")
  end

  test "a file with invalid JSON returns a structured error" do
    path =
      Path.join(System.tmp_dir!(), "signal_garden_bad_#{System.unique_integer([:positive])}.json")

    File.write!(path, "{not json")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_scenario_file, _}} = Replay.resolve(path)
  end

  # ---------------------------------------------------------------------------
  # replay behavior
  # ---------------------------------------------------------------------------

  test "replaying a catalog scenario returns a converged summary" do
    assert {:ok, replay} = Replay.replay(:ring)
    assert replay.summary.status == :converged
    assert replay.summary.outcome == :converged
    assert replay.summary.nodes == 12
    assert replay.summary.convergence_time != nil
  end

  test "two replays of the same scenario are byte-identical" do
    a = Replay.run(Scenarios.ring())
    b = Replay.run(Scenarios.ring())

    assert a.summary == b.summary
    assert a.trace == b.trace
    assert a.history == b.history
  end

  test "every catalog scenario replays deterministically" do
    for scenario <- Scenarios.catalog() do
      a = Replay.run(scenario)
      b = Replay.run(scenario)

      assert a.summary == b.summary,
             "#{scenario.id} summaries must match"

      assert a.trace == b.trace,
             "#{scenario.id} traces must match"

      assert a.history == b.history,
             "#{scenario.id} histories must match"
    end
  end

  test "a scenario file replays to the same result as the catalog scenario" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    assert {:ok, from_file} = Replay.replay(path)
    assert {:ok, from_catalog} = Replay.replay(:ring)

    assert from_file.summary == from_catalog.summary
    assert from_file.trace == from_catalog.trace
  end

  test "the trace keeps the full event log" do
    assert {:ok, replay} = Replay.replay(:ring)
    assert length(replay.trace) > 80
    assert Enum.count(replay.trace, &(&1.kind == :deliver)) == replay.summary.hops
  end

  test "lossy scenarios record dropped messages in the trace" do
    assert {:ok, replay} = Replay.replay(:lossy)
    assert replay.summary.dropped > 0
    assert Enum.any?(replay.trace, &(&1.kind in [:dropped_partition, :dropped_loss]))
  end

  test "counter scenarios record every write in the trace" do
    assert {:ok, replay} = Replay.replay(:counter)
    assert replay.summary.counter_total == 9
    assert Enum.count(replay.trace, &(&1.kind == :increment)) == replay.summary.counter_writes
  end

  test "a run with every node down exhausts instead of converging" do
    scenario = %Scenario{
      Scenarios.line()
      | fault_schedule:
          Enum.map(Scenarios.line().topology.nodes, fn id ->
            %{at: 0, action: {:crash, id}, label: "down"}
          end)
    }

    replay = Replay.run(scenario)
    assert replay.summary.status == :exhausted
    assert replay.summary.outcome == :exhausted
    assert replay.summary.convergence_time == nil
  end

  # ---------------------------------------------------------------------------
  # seed override
  # ---------------------------------------------------------------------------

  test "overriding the seed changes the run deterministically" do
    assert {:ok, a} = Replay.replay(:ring, seed: 1)
    assert {:ok, b} = Replay.replay(:ring, seed: 1)
    assert a.summary == b.summary
    assert a.trace == b.trace

    assert {:ok, c} = Replay.replay(:ring, seed: 99)
    refute a.summary.convergence_time == c.summary.convergence_time
    refute a.trace == c.trace
  end

  test "an invalid seed is rejected" do
    assert {:error, :invalid_seed} = Replay.replay(:ring, seed: -1)
  end

  # ---------------------------------------------------------------------------
  # verification
  # ---------------------------------------------------------------------------

  test "verification proves every catalog scenario deterministic" do
    report = Replay.verify()
    assert report.all_match
    assert length(report.results) == length(Scenarios.catalog())
    assert Enum.all?(report.results, & &1.match)
  end

  # ---------------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------------

  test "the summary table renders headers and rows" do
    table = Replay.format_summary_table(Replay.run_all())
    assert table =~ "scenario"
    assert table =~ "Ring"
    assert table =~ "Grow-only counter"
    assert table =~ "converged"
  end

  test "the trace renders aligned lines and a truncation note" do
    assert {:ok, replay} = Replay.replay(:ring)

    excerpt = Replay.format_trace(replay, 3)
    assert excerpt =~ "t"
    assert excerpt =~ "kind"
    assert excerpt =~ "deliver"
    assert excerpt =~ "more events"

    full = Replay.format_trace(replay)
    refute full =~ "more events"
  end

  test "the verify report renders deterministic status per scenario" do
    report = Replay.verify()
    rendered = Replay.format_verify(report)
    assert rendered =~ "line                deterministic"
    assert rendered =~ "all scenarios deterministic = true"
  end

  test "replay JSON encodes a single replay and parses back" do
    assert {:ok, replay} = Replay.replay(:ring)
    json = Replay.to_json(replay)
    assert {:ok, decoded} = Jason.decode(json)

    assert decoded["summary"]["nodes"] == 12
    assert decoded["summary"]["convergence_time"] == replay.summary.convergence_time
    assert is_list(decoded["trace"])
    assert is_list(decoded["history"])
    assert decoded["scenario"]["name"] == "Ring"
    assert decoded["scenario"]["delay_ms"] == [20, 50]
  end

  test "replay JSON encodes a list of replays" do
    json = Replay.to_json([Replay.run(Scenarios.line()), Replay.run(Scenarios.ring())])
    assert {:ok, decoded} = Jason.decode(json)
    assert length(decoded) == 2
  end

  test "verify JSON encodes the report" do
    report = Replay.verify()
    json = Replay.verify_json(report)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["all_match"] == true
    assert length(decoded["scenarios"]) == length(Scenarios.catalog())
  end

  # ---------------------------------------------------------------------------
  # core integration
  # ---------------------------------------------------------------------------

  test "a full-log core keeps early events that the default log trims" do
    scenario = Scenarios.grid()
    full = Core.new(scenario, log_size: :infinity) |> step_all()
    capped = Core.new(scenario) |> step_all()

    assert length(full.event_log) > length(capped.event_log)
    assert Enum.reverse(full.event_log) |> hd() |> Map.get(:t) == 1
    refute Enum.any?(capped.event_log, &(&1.t == 1))
  end

  defp step_all(state) do
    state
    |> Core.command({:set_status, :running})
    |> then(fn state ->
      Enum.reduce_while(1..5_000, state, fn _, acc ->
        {acc, _} = Core.step(acc, 200)

        if acc.status in [:converged, :exhausted] do
          {:halt, acc}
        else
          {:cont, acc}
        end
      end)
    end)
  end
end
