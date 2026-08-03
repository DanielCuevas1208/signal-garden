defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Replay, Scenario}

  # ---------------------------------------------------------------------------
  # determinism
  # ---------------------------------------------------------------------------

  test "two replays of the same scenario produce identical traces" do
    a = Replay.run(Scenarios.ring())
    b = Replay.run(Scenarios.ring())

    assert a == b
    assert a.summary.status == :converged
  end

  test "the ring replay matches the documented sample output" do
    trace = Replay.run(Scenarios.ring())

    assert trace.summary.convergence_time == 750
    assert trace.summary.hops == 120
    assert trace.summary.steps == 236
    assert trace.summary.dropped == 0
    assert trace.summary.informed == trace.summary.total
  end

  test "summary/2 returns the same map on every call" do
    assert Replay.summary(Scenarios.ring()) == Replay.summary(Scenarios.ring())
  end

  # ---------------------------------------------------------------------------
  # trace contents
  # ---------------------------------------------------------------------------

  test "the replay keeps the full event log and history" do
    trace = Replay.run(Scenarios.lossy())

    assert length(trace.events) == trace.summary.hops + trace.summary.dropped
    assert length(trace.history) == trace.summary.steps
    assert trace.summary.status == :converged
  end

  test "the counter replay logs every scheduled write" do
    trace = Replay.run(Scenarios.counter())

    increments = Enum.filter(trace.events, &(&1.kind == :increment))

    assert length(increments) == 5
    assert Enum.sum(Enum.map(increments, & &1.amount)) == 9
    assert trace.summary.status == :converged
    assert length(trace.events) == trace.summary.hops + trace.summary.dropped + 5
  end

  test "a permanent partition stops convergence" do
    partitions = Map.new(2..8, fn n -> {n, 1} end)
    scenario = %Scenario{Scenarios.line() | partitions: partitions}

    trace = Replay.run(scenario, budget: 10_000)

    refute trace.summary.status == :converged
    assert trace.summary.informed == 1
    assert trace.summary.convergence_time == nil
  end

  test "a small budget stops the replay early" do
    full = Replay.run(Scenarios.grid())
    partial = Replay.run(Scenarios.grid(), budget: 200)

    assert partial.summary.status == :running
    assert partial.summary.steps <= 201
    assert partial.summary.steps < full.summary.steps
  end

  # ---------------------------------------------------------------------------
  # rendering
  # ---------------------------------------------------------------------------

  test "format/2 renders a readable trace table" do
    table = Scenarios.ring() |> Replay.run() |> Replay.format(events: 5)

    assert table =~ "Scenario: Ring"
    assert table =~ "Status: converged"
    assert table =~ "Trace (first 5 of 120 events)"
    assert table =~ "delivered"
  end

  test "format_catalog/1 renders one row per scenario" do
    traces = Enum.map(Scenarios.catalog(), &Replay.run/1)
    table = Replay.format_catalog(traces)

    assert String.split(table, "\n") |> length() == length(Scenarios.catalog()) + 1
    assert table =~ "Grow-only counter"
    assert table =~ "converged"
  end

  test "list/0 shows every catalog id" do
    listed = Replay.list()

    for scenario <- Scenarios.catalog() do
      assert listed =~ Atom.to_string(scenario.id)
    end
  end

  test "a replay encodes to JSON with string keys" do
    json = Scenarios.ring() |> Replay.run() |> Jason.encode!()
    decoded = Jason.decode!(json)

    assert decoded["summary"]["status"] == "converged"
    assert decoded["scenario"]["name"] == "Ring"
    assert is_list(decoded["events"])
    assert is_list(decoded["history"])
  end
end
