defmodule Mix.Tasks.Sg.RunTest do
  use ExUnit.Case, async: true

  alias SignalGarden.Scenarios

  setup do
    Mix.shell(Mix.Shell.Process)
    :ok
  end

  test "runs a scenario and prints its trace" do
    Mix.Tasks.Sg.Run.run(["ring"])

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Scenario: Ring"
    assert output =~ "Status: converged"
    assert output =~ "Summary"
  end

  test "defaults to the line scenario" do
    Mix.Tasks.Sg.Run.run([])

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Scenario: Line"
  end

  test "--list prints the catalog" do
    Mix.Tasks.Sg.Run.run(["--list"])

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "line"
    assert output =~ "Grow-only counter"
  end

  test "--all replays every catalog scenario" do
    Mix.Tasks.Sg.Run.run(["--all"])

    assert_received {:mix_shell, :info, [output]}

    for scenario <- Scenarios.catalog() do
      assert output =~ scenario.name
    end

    assert output =~ "converged"
  end

  test "--format json emits machine-readable output" do
    Mix.Tasks.Sg.Run.run(["ring", "--format", "json"])

    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["summary"]["status"] == "converged"
    assert decoded["scenario"]["name"] == "Ring"
  end

  test "--steps stops the replay early" do
    Mix.Tasks.Sg.Run.run(["ring", "--steps", "40", "--format", "json"])

    assert_received {:mix_shell, :info, [output]}
    decoded = Jason.decode!(output)
    assert decoded["summary"]["steps"] <= 41
    assert decoded["summary"]["status"] != "converged"
  end

  test "--file replays an exported scenario file" do
    path = Path.join([:code.priv_dir(:signal_garden), "scenarios", "ring.json"])
    Mix.Tasks.Sg.Run.run(["--file", path])

    assert_received {:mix_shell, :info, [output]}
    assert output =~ "Scenario: Ring"
    assert output =~ "Status: converged"
  end

  test "an unknown scenario raises a Mix error" do
    assert_raise Mix.Error, ~r/Unknown scenario/, fn ->
      Mix.Tasks.Sg.Run.run(["nope"])
    end
  end

  test "an invalid file raises a Mix error" do
    assert_raise Mix.Error, ~r/Could not read/, fn ->
      Mix.Tasks.Sg.Run.run(["--file", "missing-scenario.json"])
    end
  end

  test "an invalid format raises a Mix error" do
    assert_raise Mix.Error, ~r/Unknown format/, fn ->
      Mix.Tasks.Sg.Run.run(["ring", "--format", "xml"])
    end
  end
end
