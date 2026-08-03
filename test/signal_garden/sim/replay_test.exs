defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.Replay

  # ---------------------------------------------------------------------------
  # replay outcomes
  # ---------------------------------------------------------------------------

  test "replaying a scenario returns a converged outcome" do
    outcome = Replay.run(Scenarios.fetch(:line))

    assert outcome.scenario == :line
    assert outcome.status == :converged
    assert outcome.convergence_time > 0
    assert outcome.nodes == 8
    assert outcome.steps > 0
  end

  test "replaying a scenario twice yields identical bytes" do
    a = Replay.run(Scenarios.fetch(:ring))
    b = Replay.run(Scenarios.fetch(:ring))

    assert a.convergence_time == b.convergence_time
    assert a.history == b.history
    assert a.trace == b.trace
  end

  test "run_all replays every catalog scenario" do
    outcomes = Replay.run_all()
    assert length(outcomes) == length(Scenarios.catalog())

    for outcome <- outcomes do
      assert outcome.status in [:converged, :exhausted]
      assert length(outcome.trace) > 0
    end
  end

  test "run_id fetches a scenario by atom" do
    assert {:ok, outcome} = Replay.run_id(:grid)
    assert outcome.name == "Grid"

    assert {:error, {:unknown_scenario, :nope}} = Replay.run_id(:nope)
  end

  test "run_file replays a codec JSON file" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    assert {:ok, outcome} = Replay.run_file(path)
    assert outcome.name == "Ring"
    assert outcome.status == :converged
  end

  test "run_file returns the codec error for a bad file" do
    path = Path.join(System.tmp_dir!(), "bad_scenario_#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"nope":))
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_json, _}} = Replay.run_file(path)
  end

  test "the counter outcome carries the final total" do
    outcome = Replay.run(Scenarios.fetch(:counter))
    assert outcome.mode == :counter
    assert outcome.counter_total == 9
  end

  # ---------------------------------------------------------------------------
  # determinism
  # ---------------------------------------------------------------------------

  test "verify confirms a scenario is deterministic" do
    report = Replay.verify(Scenarios.fetch(:lossy))

    assert report.deterministic
    assert report.events > 0
    assert report.convergence_time > 0
  end

  test "verify_all confirms every catalog scenario" do
    reports = Replay.verify_all()
    assert length(reports) == length(Scenarios.catalog())
    assert Enum.all?(reports, & &1.deterministic)
  end

  # ---------------------------------------------------------------------------
  # formatting
  # ---------------------------------------------------------------------------

  test "format_table renders a fixed-width report" do
    table = Replay.format_table([Replay.run(Scenarios.fetch(:ring))])

    assert table =~ "scenario"
    assert table =~ "Ring"
    assert table =~ "converged"
  end

  test "format_event renders each event kind" do
    assert Replay.format_event(%{t: 10, kind: :deliver, from: 1, to: 2}) ==
             "10 node 1 -> node 2 delivered"

    assert Replay.format_event(%{t: 20, kind: :dropped_loss, from: 3, to: 4}) ==
             "20 node 3 -> node 4 dropped (loss)"

    assert Replay.format_event(%{t: 30, kind: :crashed, from: 5}) == "30 node 5 crashed"

    assert Replay.format_event(%{t: 40, kind: :increment, from: 6, amount: 2}) ==
             "40 node 6 wrote +2"
  end

  test "format_trace joins the chronological trace" do
    outcome = Replay.run(Scenarios.fetch(:line))
    trace = Replay.format_trace(outcome)

    assert trace =~ "delivered"
    refute trace == ""
  end
end
