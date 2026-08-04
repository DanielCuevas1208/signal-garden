defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Sim.Replay
  alias SignalGarden.Scenarios

  # ---------------------------------------------------------------------------
  # determinism
  # ---------------------------------------------------------------------------

  test "two replays of the same scenario produce identical reports" do
    a = Replay.run(Scenarios.fetch(:ring))
    b = Replay.run(Scenarios.fetch(:ring))

    assert a == b
    assert Replay.deterministic?(Scenarios.fetch(:ring))
  end

  test "the report matches the documented sample output" do
    report = Replay.run(Scenarios.fetch(:ring))

    assert Replay.summary_line(report) ==
             "Ring                12     converged    750       120    0         236"
  end

  # ---------------------------------------------------------------------------
  # report shape
  # ---------------------------------------------------------------------------

  test "a converged replay reports the final state" do
    report = Replay.run(Scenarios.fetch(:grid))

    assert report.status == :converged
    assert report.convergence_time != nil
    assert report.clock == report.convergence_time
    assert length(report.nodes) == 30
    assert report.hops > 0
    assert report.steps > 0
  end

  test "every node is informed at convergence" do
    report = Replay.run(Scenarios.fetch(:ring))
    assert Enum.all?(report.nodes, & &1.informed)
    assert Enum.all?(report.nodes, & &1.up)
  end

  test "the trace is chronological and lists delivered messages" do
    report = Replay.run(Scenarios.fetch(:ring))

    times = Enum.map(report.trace, & &1.t)
    assert times == Enum.sort(times)
    assert Enum.any?(report.trace, &(&1.kind == :deliver))
  end

  # ---------------------------------------------------------------------------
  # fault visibility
  # ---------------------------------------------------------------------------

  test "lossy runs record dropped messages in the trace" do
    report = Replay.run(Scenarios.fetch(:lossy))

    assert report.dropped > 0
    assert Enum.any?(report.trace, &(&1.kind == :dropped_loss))
  end

  test "crash faults appear in the trace" do
    report = Replay.run(Scenarios.fetch(:crash))

    assert Enum.any?(report.trace, &(&1.kind == :crashed))
    assert Enum.any?(report.trace, &(&1.kind == :restarted))
  end

  test "partition splits appear in the trace" do
    report = Replay.run(Scenarios.fetch(:split))

    assert Enum.any?(report.trace, &(&1.kind == :dropped_partition))
    assert report.dropped > 0
  end

  # ---------------------------------------------------------------------------
  # counter mode
  # ---------------------------------------------------------------------------

  test "counter mode reports the total and the write count" do
    report = Replay.run(Scenarios.fetch(:counter))

    assert report.counter_total == 9
    assert report.counter_writes == 5
    assert Enum.all?(report.nodes, &(&1.value == 9))
  end

  test "increment faults appear in the counter trace" do
    report = Replay.run(Scenarios.fetch(:counter))

    increments = Enum.filter(report.trace, &(&1.kind == :increment))
    assert length(increments) == 5
  end

  # ---------------------------------------------------------------------------
  # options
  # ---------------------------------------------------------------------------

  test "the seed option changes the run and the report" do
    base = Replay.run(Scenarios.fetch(:ring))
    seeded = Replay.run(Scenarios.fetch(:ring), seed: 999)

    assert seeded.scenario.seed == 999
    refute seeded.convergence_time == base.convergence_time
  end

  test "the max_steps option stops the run before convergence" do
    report = Replay.run(Scenarios.fetch(:ring), max_steps: 1)

    assert report.status == :running
    assert report.convergence_time == nil
  end

  test "the log_size option caps the captured trace" do
    report = Replay.run(Scenarios.fetch(:ring), log_size: 10)

    assert length(report.trace) <= 10
  end

  # ---------------------------------------------------------------------------
  # output formats
  # ---------------------------------------------------------------------------

  test "the table header names the columns" do
    assert String.split(Replay.table_header(), ~r/\s+/) ==
             ["scenario", "nodes", "status", "t(ms)", "hops", "dropped", "steps"]
  end

  test "the trace text names the scenario and its status" do
    text = Replay.to_trace(Replay.run(Scenarios.fetch(:ring)))

    assert text =~ "scenario: Ring"
    assert text =~ "status: converged"
    assert text =~ "deliver"
  end

  test "json output is valid, complete, and deterministic" do
    a = Replay.to_json(Replay.run(Scenarios.fetch(:lossy)))
    b = Replay.to_json(Replay.run(Scenarios.fetch(:lossy)))

    assert a == b

    decoded = Jason.decode!(a)
    assert decoded["scenario"]["name"] == "Lossy link"
    assert decoded["status"] == "converged"
    assert decoded["dropped"] > 0
    assert length(decoded["nodes"]) == 14
    assert length(decoded["trace"]) > 0
  end

  test "counter json output carries the converged total" do
    decoded = Replay.run(Scenarios.fetch(:counter)) |> Replay.to_json() |> Jason.decode!()

    assert decoded["counter_total"] == 9
    assert decoded["counter_writes"] == 5
  end
end
