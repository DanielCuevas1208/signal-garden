defmodule Mix.Tasks.SignalGarden.ReplayTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.SignalGarden.Replay

  test "prints a summary table when run with no scenario" do
    output = capture_io(fn -> Replay.run([]) end)

    assert output =~ "scenario"
    assert output =~ "Line"
    assert output =~ "Grow-only counter"
    refute output =~ "Event trace"
  end

  test "prints a summary and a trace for one scenario" do
    output = capture_io(fn -> Replay.run(["ring"]) end)

    assert output =~ "Scenario: Ring"
    assert output =~ "Fingerprint:"
    assert output =~ "Event trace"
    assert output =~ "send"
  end

  test "accepts a JSON scenario file as the argument" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "counter.json"])
    output = capture_io(fn -> Replay.run([path, "--no-trace"]) end)

    assert output =~ "Scenario: Grow-only counter"
    assert output =~ "Counter total: 9 in 5 writes"
    refute output =~ "Event trace"
  end

  test "--no-trace omits the event trace" do
    output = capture_io(fn -> Replay.run(["ring", "--no-trace"]) end)

    refute output =~ "Event trace"
  end

  test "--check verifies determinism for a single scenario" do
    output = capture_io(fn -> Replay.run(["ring", "--check"]) end)

    assert output =~ "Ring: deterministic"
    assert output =~ "Fingerprint:"
  end

  test "--check verifies every built-in scenario" do
    output = capture_io(fn -> Replay.run(["--check"]) end)

    assert output =~ "deterministic"
    assert output =~ "Grow-only counter"
  end

  test "--json emits machine-readable output for one scenario" do
    output = capture_io(fn -> Replay.run(["ring", "--json"]) end)
    decoded = Jason.decode!(output)

    assert decoded["scenario"]["name"] == "Ring"
    assert decoded["status"] == "converged"
    assert decoded["fingerprint"] =~ ~r/^[0-9a-f]{64}$/
    assert is_list(decoded["events"])
  end

  test "--json emits a list of results when no scenario is given" do
    output = capture_io(fn -> Replay.run(["--json"]) end)
    decoded = Jason.decode!(output)

    assert is_list(decoded)
    assert length(decoded) == 9
    assert Enum.all?(decoded, &(&1["status"] == "converged"))
  end
end
