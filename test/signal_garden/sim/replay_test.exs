defmodule SignalGarden.Sim.ReplayTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios
  alias SignalGarden.Sim.{Replay, Scenario}

  # ---------------------------------------------------------------------------
  # determinism and convergence
  # ---------------------------------------------------------------------------

  test "a catalog scenario replays to a converged result" do
    assert {:ok, %Replay{} = replay} = Replay.run(:ring)

    assert replay.snapshot.status == :converged
    assert replay.snapshot.convergence_time == 750
    assert replay.deterministic == true
  end

  test "a counter scenario replays to the final total" do
    assert {:ok, %Replay{} = replay} = Replay.run(:counter)

    assert replay.snapshot.mode == :counter
    assert replay.snapshot.counter_total == 9
    assert replay.snapshot.counter_writes == 5
    assert replay.snapshot.reached == replay.snapshot.total
  end

  test "run_all replays every catalog scenario deterministically" do
    replays = Replay.run_all()

    assert length(replays) == length(Scenarios.catalog())
    assert Enum.all?(replays, &(&1.deterministic == true))
    assert Enum.all?(replays, &(&1.snapshot.status == :converged))
  end

  test "list exposes catalog ids" do
    ids = Enum.map(Replay.list(), &elem(&1, 0))
    assert :ring in ids
    assert :counter in ids
  end

  # ---------------------------------------------------------------------------
  # trace
  # ---------------------------------------------------------------------------

  test "the trace is ordered and ends at or before convergence" do
    assert {:ok, replay} = Replay.run(:crash)

    times = Enum.map(replay.trace, & &1.t)
    assert times == Enum.sort(times)
    assert List.last(times) <= replay.snapshot.convergence_time
    assert Enum.any?(replay.trace, &(&1.kind == :crashed))
    assert Enum.any?(replay.trace, &(&1.kind == :restarted))
  end

  test "the trace records every message event and fault without loss" do
    assert {:ok, replay} = Replay.run(:counter)

    expected =
      replay.snapshot.hops + replay.snapshot.dropped + replay.snapshot.counter_writes

    assert length(replay.trace) == expected
  end

  test "a no-fault scenario logs one trace entry per hop" do
    assert {:ok, replay} = Replay.run(:grid)
    assert length(replay.trace) == replay.snapshot.hops
    assert length(replay.trace) > 80
  end

  test "faults list the schedule and mark what fired" do
    assert {:ok, replay} = Replay.run(:split)
    assert length(replay.faults) == 5
    assert Enum.any?(replay.faults, & &1.fired)
    assert Enum.any?(replay.faults, &(not &1.fired))
  end

  # ---------------------------------------------------------------------------
  # scenario files and errors
  # ---------------------------------------------------------------------------

  test "a scenario file replays to the same result as its catalog id" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    assert {:ok, file_replay} = Replay.run_file(path)
    assert {:ok, id_replay} = Replay.run(:ring)

    assert file_replay.trace == id_replay.trace
    assert file_replay.snapshot.convergence_time == id_replay.snapshot.convergence_time
    assert file_replay.snapshot.hops == id_replay.snapshot.hops
    assert file_replay.snapshot.dropped == id_replay.snapshot.dropped
  end

  test "run rejects an unknown id" do
    assert {:error, {:unknown_scenario, :nope}} = Replay.run(:nope)
  end

  test "run_file reports a missing file" do
    assert {:error, {:file, :enoent}} = Replay.run_file("no/such/file.json")
  end

  # ---------------------------------------------------------------------------
  # stalled runs
  # ---------------------------------------------------------------------------

  test "a permanently partitioned scenario reports it did not converge" do
    scenario = %Scenario{
      Scenarios.line()
      | partitions: Map.new(1..8, fn id -> {id, if(id == 1, do: 0, else: 1)} end)
    }

    replay = Replay.run(scenario, budget: 2_000)

    refute replay.snapshot.status == :converged
    assert replay.budget_hit == true
    assert replay.deterministic == true
  end

  # ---------------------------------------------------------------------------
  # output
  # ---------------------------------------------------------------------------

  test "to_json emits a parseable document with key fields" do
    assert {:ok, replay} = Replay.run(:lossy)
    decoded = Jason.decode!(Replay.to_json(replay))

    assert decoded["scenario"]["id"] == "lossy"
    assert decoded["status"] == "converged"
    assert decoded["deterministic"] == true
    assert decoded["dropped"] > 0
    assert is_list(decoded["trace"])
    assert is_list(decoded["scenario"]["delay_ms"])
  end

  test "format renders the key lines" do
    assert {:ok, replay} = Replay.run(:ring)
    text = Replay.format(replay, trace: 3)

    assert text =~ "Signal Garden replay"
    assert text =~ "Ring"
    assert text =~ "converged"
    assert text =~ "two runs identical"
    assert text =~ "T="
  end

  test "format_table renders one row per scenario" do
    text = Replay.format_table(Replay.run_all())

    assert text =~ "scenario"
    assert text =~ "Grow-only counter"
    assert text =~ "converged"
  end

  test "format_error covers the common failures" do
    assert Replay.format_error({:unknown_scenario, :nope}) =~ "Unknown scenario"
    assert Replay.format_error({:file, :enoent}) =~ "Cannot read"

    assert Replay.format_error({:decode, {:invalid_json, %Jason.DecodeError{}}}) =~
             "not valid JSON"
  end
end
