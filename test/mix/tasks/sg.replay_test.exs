defmodule Mix.Tasks.Sg.ReplayTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Sg.Replay

  test "prints a summary and a trace for a catalog scenario" do
    output = capture_io(fn -> Replay.run(["ring"]) end)

    assert output =~ "Replay: Ring (ring)"
    assert output =~ "status          converged"
    assert output =~ "Trace (120 events)"
    assert output =~ "delivered"
  end

  test "no-trace prints the summary only" do
    output = capture_io(fn -> Replay.run(["ring", "--no-trace"]) end)
    refute output =~ "Trace ("
  end

  test "checks replays twice and confirms determinism" do
    output = capture_io(fn -> Replay.run(["ring", "--no-trace", "--checks"]) end)
    assert output =~ "trace equal            = true"
  end

  test "json output decodes and carries the full trace" do
    output = capture_io(fn -> Replay.run(["ring", "--json"]) end)
    map = Jason.decode!(output)

    assert map["status"] == "converged"
    assert map["scenario"]["id"] == "ring"
    assert length(map["trace"]) > 0
  end

  test "a scenario file path replays" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    output = capture_io(fn -> Replay.run([path, "--no-trace"]) end)
    assert output =~ "Replay: Ring (ring)"
  end

  test "an unknown scenario raises a clear error" do
    assert_raise Mix.Error, ~r/unknown scenario/, fn ->
      capture_io(fn -> Replay.run(["no_such_scenario"]) end)
    end
  end
end
