defmodule Mix.Tasks.SignalGarden.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.SignalGarden.Replay

  @stalled_path Path.join([:code.priv_dir(:signal_garden), "scenarios", "stalled.json"])

  test "prints a summary table for a single scenario" do
    output = capture_io(fn -> Replay.run(["ring"]) end)

    assert output =~ "Ring"
    assert output =~ "converged"
    assert output =~ "nodes"
  end

  test "prints a summary table for every catalog scenario by default" do
    output = capture_io(fn -> Replay.run([]) end)

    assert output =~ "Line"
    assert output =~ "Grow-only counter"
    assert length(String.split(output, "converged")) >= 10
  end

  test "emits machine-readable JSON summaries" do
    output = capture_io(fn -> Replay.run(["--json", "ring"]) end)

    assert {:ok, [summary]} = Jason.decode(output)
    assert summary["id"] == "ring"
    assert summary["status"] == "converged"
  end

  test "emits the event trace as JSON" do
    output = capture_io(fn -> Replay.run(["--trace", "line"]) end)

    assert {:ok, trace} = Jason.decode(output)
    assert is_list(trace)
    assert Enum.all?(trace, &Map.has_key?(&1, "kind"))
  end

  test "exports a complete trace artifact" do
    path =
      Path.join(
        System.tmp_dir!(),
        "signal-garden-task-trace-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    output = capture_io(fn -> Replay.run(["--export-trace", path, "grid"]) end)
    artifact = path |> File.read!() |> Jason.decode!()

    assert output =~ "wrote #{path}"
    assert artifact["scenario"]["id"] == "grid"
    assert artifact["event_count"] > 80
    assert length(artifact["events"]) == artifact["event_count"]
  end

  test "prints a compact stalled counterexample" do
    output = capture_io(fn -> Replay.run(["--counterexample", @stalled_path]) end)
    evidence = Jason.decode!(output)

    assert evidence["status"] == "stalled"
    assert evidence["isolated_nodes"] == [3, 4]
    refute Map.has_key?(evidence, "events")
  end

  test "exports a stalled counterexample artifact" do
    path =
      Path.join(
        System.tmp_dir!(),
        "signal-garden-task-counterexample-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)

    output =
      capture_io(fn ->
        Replay.run(["--export-counterexample", path, @stalled_path])
      end)

    evidence = path |> File.read!() |> Jason.decode!()

    assert output =~ "wrote #{path}"
    assert evidence["status"] == "stalled"
    assert evidence["blocking_event_count"] > 0
  end

  test "emits paired summaries, deltas, and traces as JSON" do
    output = capture_io(fn -> Replay.run(["--compare", "ring", "cut"]) end)

    assert {:ok, comparison} = Jason.decode(output)
    assert comparison["left"]["id"] == "ring"
    assert comparison["right"]["id"] == "cut"
    assert is_integer(comparison["deltas"]["hops"])
    assert is_list(comparison["traces"]["left"])
    assert is_list(comparison["traces"]["right"])
  end

  test "documents the paired comparison option" do
    output = capture_io(fn -> Replay.run(["--help"]) end)

    assert output =~ "--compare"
    assert output =~ "--export-trace"
    assert output =~ "--counterexample"
    assert output =~ "exactly two"
  end

  test "a determinism check prints an ok line" do
    output = capture_io(fn -> Replay.run(["--check", "ring"]) end)
    assert output =~ "ok"
    assert output =~ "Ring"
  end
end
