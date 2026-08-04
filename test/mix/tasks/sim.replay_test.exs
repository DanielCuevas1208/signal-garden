defmodule Mix.Tasks.Sim.ReplayTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Sim.Replay

  setup do
    Mix.shell(Mix.Shell.Process)

    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    :ok
  end

  test "runs a named scenario and prints a report" do
    Replay.run(["ring"])

    output = shell_output()

    assert output =~ "Scenario: Ring"
    assert output =~ "converged"
  end

  test "runs every catalog scenario in table mode" do
    Replay.run([])

    output = shell_output()

    assert output =~ "Line"
    assert output =~ "Grow-only counter"
    assert output =~ "converged"
  end

  test "emits JSON for a scenario" do
    Replay.run(["ring", "--json"])

    output = shell_output()
    map = Jason.decode!(output)

    assert map["scenario"]["id"] == "ring"
    assert map["result"]["status"] == "converged"
  end

  test "verifies determinism with the check flag" do
    Replay.run(["ring", "--check"])

    output = shell_output()

    assert output =~ "Determinism check"
    assert output =~ "equal = true"
  end

  test "raises on an unknown target" do
    assert_raise Mix.Error, fn -> Replay.run(["nope"]) end
  end

  defp shell_output do
    collect_shell([])
  end

  defp collect_shell(acc) do
    receive do
      {:mix_shell, :info, [text]} -> collect_shell([text | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
