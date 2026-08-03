defmodule Mix.Tasks.SignalGardenReplayTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.SignalGarden.Replay

  test "the task replays a catalog scenario as text" do
    output = capture_io(fn -> Replay.run(["counter", "--events", "3"]) end)

    assert output =~ "Signal Garden replay"
    assert output =~ "Grow-only counter"
    assert output =~ "converged"
    assert output =~ "T="
  end

  test "the task prints parseable JSON with --json" do
    output = capture_io(fn -> Replay.run(["ring", "--json"]) end)
    decoded = Jason.decode!(output)

    assert decoded["scenario"]["id"] == "ring"
    assert decoded["status"] == "converged"
    assert decoded["deterministic"] == true
  end

  test "the task replays a scenario file" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    output = capture_io(fn -> Replay.run([path, "--events", "0"]) end)
    assert output =~ "Ring"
    assert output =~ "converged"
  end

  test "the task replays every scenario when no target is given" do
    output = capture_io(fn -> Replay.run([]) end)

    assert output =~ "Grow-only counter"
    assert output =~ "converged"
  end

  test "the task lists the catalog with --list" do
    output = capture_io(fn -> Replay.run(["--list"]) end)

    assert output =~ "ring"
    assert output =~ "Grow-only counter"
  end

  test "the task exits non-zero for an unknown scenario" do
    assert capture_io(:stderr, fn ->
             capture_io(fn ->
               assert catch_exit(Replay.run(["nope"])) == {:shutdown, 1}
             end)
           end)
  end

  test "the task exits non-zero for a run that does not converge" do
    assert capture_io(:stderr, fn ->
             capture_io(fn ->
               assert catch_exit(Replay.run(["counter", "--budget", "2", "--no-check"])) ==
                        {:shutdown, 2}
             end)
           end)
  end
end
