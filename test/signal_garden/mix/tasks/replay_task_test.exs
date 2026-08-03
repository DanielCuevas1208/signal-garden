defmodule Mix.Tasks.SignalGarden.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.SignalGarden.Replay

  @scenario_names [
    "Line",
    "Ring",
    "Grid",
    "Random graph",
    "Healing partition",
    "Churn",
    "Lossy link",
    "Crash and recover",
    "Grow-only counter"
  ]

  test "replaying a single scenario prints an aligned table" do
    output = capture_io(fn -> Replay.run(["ring"]) end)
    assert output =~ "scenario"
    assert output =~ "t(ms)"
    assert output =~ "Ring"
    assert output =~ "converged"
  end

  test "replaying with no target prints every catalog row" do
    output = capture_io(fn -> Replay.run([]) end)

    for name <- @scenario_names do
      assert output =~ name
    end
  end

  test "the trace flag appends the event trace for a single target" do
    output = capture_io(fn -> Replay.run(["--trace", "ring"]) end)
    assert output =~ "deliver"
    assert output =~ "kind"
  end

  test "the json flag prints a single parseable replay object" do
    output = capture_io(fn -> Replay.run(["--json", "ring"]) end)
    assert {:ok, decoded} = Jason.decode(output)

    assert decoded["summary"]["nodes"] == 12
    assert decoded["summary"]["convergence_time"] == 750
    assert is_list(decoded["trace"])
    assert is_list(decoded["history"])
  end

  test "the json flag over the whole catalog prints an array" do
    output = capture_io(fn -> Replay.run(["--json"]) end)
    assert {:ok, decoded} = Jason.decode(output)
    assert length(decoded) == 9
  end

  test "a scenario file replays from the command line" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    output = capture_io(fn -> Replay.run([path]) end)
    assert output =~ "Ring"
    assert output =~ "converged"
  end

  test "the seed flag changes the reported convergence time" do
    a = capture_io(fn -> Replay.run(["--json", "ring", "--seed", "1"]) end)
    b = capture_io(fn -> Replay.run(["--json", "ring", "--seed", "99"]) end)

    {:ok, json_a} = Jason.decode(a)
    {:ok, json_b} = Jason.decode(b)

    refute json_a["summary"]["convergence_time"] == json_b["summary"]["convergence_time"]
  end

  test "verify prints a deterministic report and does not raise" do
    output = capture_io(fn -> Replay.run(["--verify"]) end)
    assert output =~ "all scenarios deterministic = true"
    assert output =~ "ring                deterministic"
  end

  test "list prints the catalog ids and names" do
    output = capture_io(fn -> Replay.run(["--list"]) end)
    assert output =~ "ring"
    assert output =~ "counter"
    assert output =~ "Grow-only counter"
  end

  test "an unknown target raises Mix.Error" do
    assert_raise Mix.Error, ~r/Unknown scenario or file/, fn ->
      capture_io(:stderr, fn -> Replay.run(["nope"]) end)
    end
  end

  test "an invalid seed raises Mix.Error" do
    assert_raise Mix.Error, ~r/Seed must be a non-negative integer/, fn ->
      capture_io(:stderr, fn -> Replay.run(["ring", "--seed", "-3"]) end)
    end
  end
end
