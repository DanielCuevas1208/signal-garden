defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Replay, Scenario}

  # ---------------------------------------------------------------------------
  # run/2
  # ---------------------------------------------------------------------------

  test "a healthy scenario replays to convergence" do
    report = Replay.run(Scenarios.fetch(:ring))

    assert report.status == :converged
    assert report.convergence_time != nil
    assert report.steps > 0
    assert report.budget_exhausted? == false
    assert List.last(report.trace) == {:converged, report.convergence_time}
  end

  test "the trace is ordered and consistent with the counters" do
    report = Replay.run(Scenarios.fetch(:ring))

    times = Enum.map(report.trace, &elem(&1, 1))
    assert times == Enum.sort(times)

    sends = Enum.count(report.trace, &match?({:deliver, _, _, _}, &1))
    assert sends == report.hops
  end

  test "crash and restart faults appear in the trace in order" do
    report = Replay.run(Scenarios.fetch(:crash))

    assert {:crashed, 500, 4} in report.trace
    assert {:crashed, 700, 9} in report.trace
    assert {:restarted, 1500, 4} in report.trace
    assert {:restarted, 1700, 9} in report.trace
  end

  test "counter replays capture every write and the final total" do
    report = Replay.run(Scenarios.fetch(:counter))

    assert report.status == :converged
    assert report.counter_total == 9
    assert report.counter_writes == 5

    writes = Enum.filter(report.trace, &match?({:increment, _, _, _}, &1))
    assert length(writes) == 5
  end

  test "partition assignments appear in a split scenario trace" do
    report = Replay.run(Scenarios.fetch(:split))

    assert {:partition, 400, 9, 1} in report.trace
    assert {:partition, 580, 14, 1} in report.trace
  end

  test "a small max_steps budget marks the run as stalled" do
    report = Replay.run(Scenarios.fetch(:ring), max_steps: 10)

    assert report.status == :exhausted
    assert report.budget_exhausted? == true
    assert report.steps == 11
  end

  test "a run whose nodes all crash stalls on an empty queue" do
    scenario = %Scenario{
      Scenarios.line()
      | fault_schedule:
          Enum.map(1..8, fn id -> %{at: id * 10, action: {:crash, id}, label: "crash"} end)
    }

    report = Replay.run(scenario, max_steps: 50_000)

    assert report.status == :exhausted
    assert report.budget_exhausted? == false
    assert Enum.any?(report.trace, &match?({:exhausted, _time}, &1))
  end

  # ---------------------------------------------------------------------------
  # run_all / resolve
  # ---------------------------------------------------------------------------

  test "run_all replays every built-in scenario" do
    reports = Replay.run_all()

    assert length(reports) == 9
    assert Enum.all?(reports, &(&1.status in [:converged, :exhausted]))
  end

  test "resolve maps a catalog id and a scenario file" do
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve("ring")
    assert {:ok, %Scenario{id: :ring}} = Replay.resolve("priv/scenarios/ring.json")
  end

  test "resolve rejects an unknown target" do
    assert {:error, {:unknown_scenario, "nope"}} = Replay.resolve("nope")
  end

  test "resolve reports a malformed scenario file" do
    path = tmp_file("replay-invalid-json", "{not json")

    assert {:error, {:invalid_json, _reason}} = Replay.resolve(path)
  end

  test "resolve_error turns a rejection into text" do
    assert Replay.resolve_error({:unknown_scenario, "nope"}) =~ "No scenario named"
  end

  # ---------------------------------------------------------------------------
  # check/2
  # ---------------------------------------------------------------------------

  test "check confirms a scenario replays deterministically" do
    checks = Replay.check(Scenarios.fetch(:counter))

    assert Enum.all?(checks, fn {_name, ok} -> ok end)
  end

  test "check compares the full report, not just convergence time" do
    checks = Replay.check(Scenarios.fetch(:crash))

    assert checks.trace == true
    assert checks.history == true
    assert checks.result == true
  end

  # ---------------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------------

  test "render summarizes a report and shows the trace tail" do
    text = Replay.render(Replay.run(Scenarios.fetch(:ring)))

    assert text =~ "Scenario: Ring"
    assert text =~ "Result:"
    assert text =~ "converged"
    assert text =~ "Trace"
  end

  test "render with trace shows the full event trace" do
    report = Replay.run(Scenarios.fetch(:ring))

    full = Replay.render(report, trace: true)
    default = Replay.render(report)

    assert String.split(full, "\n") |> length() > 100
    assert String.split(default, "\n") |> length() < 30
  end

  test "render_check reports each determinism field" do
    text = Replay.render_check(Replay.check(Scenarios.fetch(:ring)))

    assert text =~ "Determinism check"
    assert text =~ "equal = true"
  end

  test "render_table lists every built-in scenario" do
    text = Replay.render_table(Replay.run_all())

    assert text =~ "Line"
    assert text =~ "Ring"
    assert text =~ "Grid"
    assert text =~ "Grow-only counter"
    assert text =~ "converged"
  end

  test "render_json returns valid JSON with a full trace" do
    json = Replay.render_json(Replay.run(Scenarios.fetch(:ring)))
    map = Jason.decode!(json)

    assert map["scenario"]["id"] == "ring"
    assert map["result"]["status"] == "converged"
    assert is_list(map["trace"])
    assert List.last(map["trace"])["kind"] == "converged"
  end

  test "render_json_check embeds the determinism result" do
    report = Replay.run(Scenarios.fetch(:ring))
    checks = Replay.check(Scenarios.fetch(:ring))
    map = Jason.decode!(Replay.render_json_check(report, checks))

    assert map["determinism"]["trace"] == true
  end

  test "status_label maps statuses to words" do
    assert Replay.status_label(:converged) == "converged"
    assert Replay.status_label(:exhausted) == "stalled"
    assert Replay.status_label(:idle) == "ready"
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}.json")

    File.write!(path, contents)

    on_exit(fn -> File.rm(path) end)

    path
  end
end
