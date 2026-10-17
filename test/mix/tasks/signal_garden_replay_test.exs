defmodule Mix.Tasks.SignalGarden.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.SignalGarden.Replay

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
    assert output =~ "exactly two"
  end

  test "a determinism check prints an ok line" do
    output = capture_io(fn -> Replay.run(["--check", "ring"]) end)
    assert output =~ "ok"
    assert output =~ "Ring"
  end
end
